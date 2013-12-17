{-# LANGUAGE PatternGuards #-}

module Idris.Erasure
    ( findUnusedArgs
    , findUsed
    ) where

import Idris.AbsSyntax
import Idris.Core.CaseTree
import Idris.Core.TT
import Idris.Core.Evaluate

import Control.Applicative
import Control.Monad.State
import Data.Maybe
import Data.List
import qualified Data.Set as S
import qualified Data.IntSet as IS
import qualified Data.Map as M
import Data.Set (Set)
import Data.IntSet (IntSet)
import Data.Map (Map)

-- UseMap maps names to the set of used argument positions.
type UseMap = Map Name IntSet

-- PatvarMap maps pattern variable names to the corresponding (data-ctor-name, argpos).
type PatvarMap = Map Name (Name, Int)

findUsed :: Context -> Ctxt CGInfo -> [Name] -> UseMap
findUsed ctx cg = unionMap $ findUsedDef cg . getDef ctx
  where
    unionMap :: (a -> UseMap) -> [a] -> UseMap
    unionMap f = M.unionsWith IS.union . map f

    getDef :: Context -> Name -> Def
    getDef ctx n = case lookupDef n ctx of
        [def] -> def
        [] -> error $ "erasure checker: unknown name: " ++ show n  -- TODO: fix this
        _  -> error $ "erasure checker: ambiguous name: " ++ show n  -- TODO: fix this

    findUsedDef :: Ctxt CGInfo -> Def -> UseMap
    findUsedDef cg (Function ty t  ) = M.empty
    findUsedDef cg (TyDecl   ty t  ) = M.empty
    findUsedDef cg (Operator ty n f) = M.empty
    --  ^- non-pattern-matching definitions don't contribute to usage of data
    
    findUsedDef cg (CaseOp ci ty def tot cdefs)
        -- the fst component is the list of pattern variables, which we don't use
        = findUsedSC cg M.empty (snd $ cases_compiletime cdefs)  -- TODO: or cases_runtime?

    findUsedSC :: Ctxt CGInfo -> PatvarMap -> SC -> UseMap
    findUsedSC cg vars  ImpossibleCase     = M.empty
    findUsedSC cg vars (UnmatchedCase msg) = M.empty
    findUsedSC cg vars (Case     n alts) = unionMap (findUsedAlt cg vars) alts
    findUsedSC cg vars (ProjCase t alt) = findUsedAlt cg vars alt
    findUsedSC cg vars (STerm t) = unionMap lookUp . S.toList $ findUsedTerm cg t
      where
        lookUp :: Name -> UseMap
        lookUp n = case M.lookup n vars of
            Just (cn, i) -> M.singleton cn (IS.singleton i)
            Nothing      -> M.empty

    findUsedAlt :: Ctxt CGInfo -> PatvarMap -> CaseAlt -> UseMap
    findUsedAlt cg vars (FnCase n ns sc) = findUsedSC cg vars sc  -- TODO: what's this?
    findUsedAlt cg vars (ConstCase c sc) = findUsedSC cg vars sc
    findUsedAlt cg vars (SucCase n sc) = findUsedSC cg (M.insert n (error "put S here") vars) sc  -- TODO
    findUsedAlt cg vars (DefaultCase sc) = findUsedSC cg vars sc
    findUsedAlt cg vars (ConCase n cnt ns sc) = findUsedSC cg (ns `u` vars) sc
      where
        u :: [Name] -> PatvarMap -> PatvarMap
        vs `u` pmap = M.fromList [(var, (n, i)) | (i, var) <- zip [0..] vs] `M.union` pmap

    -- Find used pattern variables in the given term.
    findUsedTerm :: Ctxt CGInfo -> Term -> Set Name
    findUsedTerm cg (P _ n _) = S.singleton n
    findUsedTerm cg (Bind n (Let t v) body) = S.unions
        [ findUsedTerm cg v
        , S.delete n $ findUsedTerm cg body
        , findUsedTerm cg t ]
    findUsedTerm cg (Bind n b t) = S.unions
        [ findUsedTerm cg (binderTy b)
        , S.delete n $ findUsedTerm cg t ]
    findUsedTerm cg (Proj t i) = findUsedTerm cg t
    findUsedTerm cg t@(App _ _) | (P _ n _, args) <- unApply t
        = let unused = case lookupCtxt n cg of
                [cgi] -> unusedpos cgi
                _     -> []
          in S.unions [findUsedTerm cg arg | (i,arg) <- zip [0..] args, i `notElem` unused]
    findUsedTerm cg _ = S.empty
        
findUnusedArgs :: [Name] -> Idris ()
findUnusedArgs names = do
    cg <- idris_callgraph <$> getIState
    mapM_ (process cg) names
  where
    process :: Ctxt CGInfo -> Name -> Idris ()
    process cg n = case lookupCtxt n cg of
        [x] -> do
            let unused = traceUnused cg n x 
            logLvl 1 $ show n ++ " unused: " ++ show unused
            addToCG n $ x{ unusedpos = unused }
        _ -> return ()

    traceUnused :: Ctxt CGInfo -> Name -> CGInfo -> [Int]
    traceUnused cg n (CGInfo args calls _ usedns _)
        = findIndices (not . (`elem` fused)) args
      where
        fargs   = concatMap (getFargpos calls) (zip args [0..])
        recused = [n | (n, i, (g,j)) <- fargs, used cg [(n,i)] g j]
        fused   = nub $ usedns ++ recused
        
    used :: Ctxt CGInfo -> [(Name, Int)] -> Name -> Int -> Bool
    used cg path g j
        | (g, j) `elem` path = False -- cycle, never used on the way

        | [CGInfo args calls _ usedns _] <- lookupCtxt g cg
        , j < length args  -- not overapplied
        = let directuse = args!!j `elem` usedns
              garg      = getFargpos calls (args!!j, j)
              recused   = map getUsed garg
          in directuse || null recused || or recused
          -- used on any route from here, or not used recursively

        | otherwise = True
      where
        getUsed (argn, j, (g', j')) = used cg ((g,j):path) g' j'

    getFargpos :: [(Name, [[Name]])] -> (Name, Int) -> [(Name, Int, (Name, Int))]
    getFargpos calls (n, i) = concatMap (getCallArgpos n i) calls
      where
        getCallArgpos :: Name -> Int -> (Name, [[Name]]) -> [(Name, Int, (Name, Int))]
        getCallArgpos n i (g, args) = mapMaybe (getOne g) (zip [0..] args)
        
        getOne :: Name -> (Int, [Name]) -> Maybe (Name, Int, (Name, Int))
        getOne g (j, xs)
            | n `elem` xs = Just (n, i, (g, j))
            | otherwise   = Nothing
