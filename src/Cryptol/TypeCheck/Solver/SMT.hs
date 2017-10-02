-- |
-- Module      :  $Header$
-- Copyright   :  (c) 2013-2016 Galois, Inc.
-- License     :  BSD3
-- Maintainer  :  cryptol@galois.com
-- Stability   :  provisional
-- Portability :  portable
{-# LANGUAGE Safe #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE FlexibleContexts #-}
{-# Language FlexibleInstances #-}
{-# LANGUAGE PatternGuards #-}
{-# LANGUAGE TypeSynonymInstances #-}

module Cryptol.TypeCheck.Solver.SMT
  ( -- * Setup
    Solver
  , withSolver

    -- * Debugging
  , debugBlock
  , debugLog

    -- * Proving stuff
  , proveImp
  , checkUnsolvable
  , tryGetModel
  ) where

import           SimpleSMT (SExpr)
import qualified SimpleSMT as SMT
import           Data.Map ( Map )
import qualified Data.Map as Map
import qualified Data.Set as Set
import           Data.Maybe(catMaybes)
import           Data.List(partition)
import           Control.Exception
import           Control.Monad(msum,zipWithM,void)
import           Data.Char(isSpace)
import           Text.Read(readMaybe)
import qualified System.IO.Strict as StrictIO
import           System.FilePath((</>))
import           System.Directory(doesFileExist)

import Cryptol.Prelude(cryptolTcContents)
import Cryptol.TypeCheck.Type
import Cryptol.TypeCheck.InferTypes
import Cryptol.TypeCheck.TypePat hiding ((~>),(~~>))
import Cryptol.TypeCheck.Subst(Subst, emptySubst, listSubst)
import Cryptol.Utils.Panic
import Cryptol.Utils.PP -- ( Doc )



-- | An SMT solver packed with a logger for debugging.
data Solver = Solver
  { solver    :: SMT.Solver
    -- ^ The actual solver

  , logger    :: SMT.Logger
    -- ^ For debugging
  }

-- | Execute a computation with a fresh solver instance.
withSolver :: SolverConfig -> (Solver -> IO a) -> IO a
withSolver SolverConfig{ .. } =
     bracket
       (do logger <- if solverVerbose > 0 then SMT.newLogger 0 else return quietLogger
           let smtDbg = if solverVerbose > 1 then Just logger else Nothing
           solver <- SMT.newSolver solverPath solverArgs smtDbg
           _ <- SMT.setOptionMaybe solver ":global-decls" "false"
           -- SMT.setLogic solver "QF_LIA"
           let sol = Solver { .. }
           loadTcPrelude sol solverPreludePath
           return sol)
       (\s -> void $ SMT.stop (solver s))

  where
  quietLogger = SMT.Logger { SMT.logMessage = \_ -> return ()
                           , SMT.logLevel   = return 0
                           , SMT.logSetLevel= \_ -> return ()
                           , SMT.logTab     = return ()
                           , SMT.logUntab   = return ()
                           }


-- | Load the definitions used for type checking.
loadTcPrelude :: Solver -> [FilePath] {- ^ Search in this paths -} -> IO ()
loadTcPrelude s [] = loadString s cryptolTcContents
loadTcPrelude s (p : ps) =
  do let file = p </> "CryptolTC.z3"
     yes <- doesFileExist file
     if yes then loadFile s file
            else loadTcPrelude s ps


loadFile :: Solver -> FilePath -> IO ()
loadFile s file = loadString s =<< StrictIO.readFile file

loadString :: Solver -> String -> IO ()
loadString s str = go (dropComments str)
  where
  go txt
    | all isSpace txt = return ()
    | otherwise =
      case SMT.readSExpr txt of
        Just (e,rest) -> SMT.command (solver s) e >> go rest
        Nothing       -> panic "loadFile" [ "Failed to parse SMT file."
                                          , txt
                                          ]

  dropComments = unlines . map dropComment . lines
  dropComment xs = case break (== ';') xs of
                     (as,_:_) -> as
                     _ -> xs




--------------------------------------------------------------------------------
-- Debugging


debugBlock :: Solver -> String -> IO a -> IO a
debugBlock s@Solver { .. } name m =
  do debugLog s name
     SMT.logTab logger
     a <- m
     SMT.logUntab logger
     return a

class DebugLog t where
  debugLog :: Solver -> t -> IO ()

  debugLogList :: Solver -> [t] -> IO ()
  debugLogList s ts = case ts of
                        [] -> debugLog s "(none)"
                        _  -> mapM_ (debugLog s) ts

instance DebugLog Char where
  debugLog s x     = SMT.logMessage (logger s) (show x)
  debugLogList s x = SMT.logMessage (logger s) x

instance DebugLog a => DebugLog [a] where
  debugLog = debugLogList

instance DebugLog a => DebugLog (Maybe a) where
  debugLog s x = case x of
                   Nothing -> debugLog s "(nothing)"
                   Just a  -> debugLog s a

instance DebugLog Doc where
  debugLog s x = debugLog s (show x)

instance DebugLog Type where
  debugLog s x = debugLog s (pp x)

instance DebugLog Goal where
  debugLog s x = debugLog s (goal x)

instance DebugLog Subst where
  debugLog s x = debugLog s (pp x)
--------------------------------------------------------------------------------





-- | Returns goals that were not proved
proveImp :: Solver -> [Prop] -> [Goal] -> IO [Goal]
proveImp sol ps gs0 =
  debugBlock sol "PROVE IMP" $
  do let gs1       = concatMap flatGoal gs0
         (gs,rest) = partition (isNumeric . goal) gs1
         numAsmp   = filter isNumeric (concatMap pSplitAnd ps)
         vs        = Set.toList (fvs (numAsmp, map goal gs))
     tvs <- debugBlock sol "VARIABLES" $
       do SMT.push (solver sol)
          Map.fromList <$> zipWithM (declareVar sol) [ 0 .. ] vs
     debugBlock sol "ASSUMPTIONS" $
       mapM_ (assume sol tvs) numAsmp
     gs' <- mapM (prove sol tvs) gs
     SMT.pop (solver sol)
     return (catMaybes gs' ++ rest)

-- | Check if the given goals are known to be unsolvable.
checkUnsolvable :: Solver -> [Goal] -> IO Bool
checkUnsolvable sol gs0 =
  debugBlock sol "CHECK UNSOLVABLE" $
  do let ps = filter isNumeric
            $ map goal
            $ concatMap flatGoal gs0
         vs = Set.toList (fvs ps)
     tvs <- debugBlock sol "VARIABLES" $
       do push sol
          Map.fromList <$> zipWithM (declareVar sol) [ 0 .. ] vs
     ans <- unsolvable sol tvs ps
     pop sol
     return ans

tryGetModel :: Solver -> [TVar] -> [Prop] -> IO (Maybe Subst)
tryGetModel sol as ps =
  do push sol
     tvs <- Map.fromList <$> zipWithM (declareVar sol) [ 0 .. ] as
     mapM_ (assume sol tvs) ps
     sat <- SMT.check (solver sol)
     su <- case sat of
             SMT.Sat ->
               case as of
                 [] -> return (Just emptySubst)
                 _ -> do res <- SMT.getExprs (solver sol) (Map.elems tvs)
                         let parse x = do e <- Map.lookup x tvs
                                          t <- parseNum =<< lookup e res
                                          return (x, t)
                         return (listSubst <$> mapM parse as)
             _ -> return Nothing
     pop sol
     return su

  where
  parseNum a
    | SMT.Other s <- a
    , SMT.List [con,val,isFin,isErr] <- s
    , SMT.Atom "mk-infnat" <- con
    , SMT.Atom "false"     <- isErr
    , SMT.Atom fin         <- isFin
    , SMT.Atom v           <- val
    , Just n               <- readMaybe v
    = Just (if fin == "false" then tInf else tNum (n :: Integer))

  parseNum _ = Nothing

--------------------------------------------------------------------------------

push :: Solver -> IO ()
push sol = SMT.push (solver sol)

pop :: Solver -> IO ()
pop sol = SMT.pop (solver sol)


declareVar :: Solver -> Int -> TVar -> IO (TVar, SExpr)
declareVar s x v =
  do let name = (if isFreeTV v then "fv" else "kv") ++ show x
     e <- SMT.declare (solver s) name cryInfNat
     SMT.assert (solver s) (SMT.fun "cryVar" [ e ])
     return (v,e)

assume :: Solver -> TVars -> Prop -> IO ()
assume s tvs p = SMT.assert (solver s) (SMT.fun "cryAssume" [ toSMT tvs p ])

prove :: Solver -> TVars -> Goal -> IO (Maybe Goal)
prove sol tvs g =
  debugBlock sol "PROVE" $
  do let s = solver sol
     push sol
     SMT.assert s (SMT.fun "cryProve" [ toSMT tvs (goal g) ])
     res <- SMT.check s
     pop sol
     case res of
       SMT.Unsat -> return Nothing
       _         -> return (Just g)


-- | Check if some numeric goals are known to be unsolvable.
unsolvable :: Solver -> TVars -> [Prop] -> IO Bool
unsolvable sol tvs ps =
  debugBlock sol "UNSOLVABLE" $
  do SMT.push (solver sol)
     mapM_ (assume sol tvs) ps
     res <- SMT.check (solver sol)
     SMT.pop (solver sol)
     case res of
       SMT.Unsat -> return True
       _         -> return False



--------------------------------------------------------------------------------

-- | Split up the 'And' in a goal
flatGoal :: Goal -> [Goal]
flatGoal g = [ g { goal = p } | p <- pSplitAnd (goal g) ]


-- | Assumes no 'And'
isNumeric :: Prop -> Bool
isNumeric ty = matchDefault False $ msum [ is (|=|), is (|>=|), is aFin ]
  where
  is f = f ty >> return True


--------------------------------------------------------------------------------

type TVars = Map TVar SExpr

cryInfNat :: SExpr
cryInfNat = SMT.const "InfNat"


toSMT :: TVars -> Type -> SExpr
toSMT tvs ty = matchDefault (panic "toSMT" [ "Unexpected type", show ty ])
  $ msum $ map (\f -> f tvs ty)
  [ aInf            ~> "cryInf"
  , aNat            ~> "cryNat"

  , aFin            ~> "cryFin"
  , (|=|)           ~> "cryEq"
  , (|>=|)          ~> "cryGeq"
  , aAnd            ~> "cryAnd"
  , aTrue           ~> "cryTrue"

  , anAdd           ~> "cryAdd"
  , (|-|)           ~> "crySub"
  , aMul            ~> "cryMul"
  , (|^|)           ~> "cryExp"
  , (|/|)           ~> "cryDiv"
  , (|%|)           ~> "cryMod"
  , aMin            ~> "cryMin"
  , aMax            ~> "cryMax"
  , aWidth          ~> "cryWidth"
  , aLenFromThen    ~> "cryLenFromThen"
  , aLenFromThenTo  ~> "cryLenFromThenTo"

  , anError KNum    ~> "cryErr"
  , anError KProp   ~> "cryErrProp"

  , aTVar           ~> "(unused)"
  ]

--------------------------------------------------------------------------------

(~>) :: Mk a => (Type -> Match a) -> String -> TVars -> Type -> Match SExpr
(m ~> f) tvs t = m t >>= \a -> return (mk tvs f a)

class Mk t where
  mk :: TVars -> String -> t -> SExpr

instance Mk () where
  mk _ f _ = SMT.const f

instance Mk Integer where
  mk _ f x = SMT.fun f [ SMT.int x ]

instance Mk TVar where
  mk tvs _ x = tvs Map.! x

instance Mk Type where
  mk tvs f x = SMT.fun f [toSMT tvs x]

instance Mk TCErrorMessage where
  mk _ f _ = SMT.fun f []

instance Mk (Type,Type) where
  mk tvs f (x,y) = SMT.fun f [ toSMT tvs x, toSMT tvs y]

instance Mk (Type,Type,Type) where
  mk tvs f (x,y,z) = SMT.fun f [ toSMT tvs x, toSMT tvs y, toSMT tvs z ]

--------------------------------------------------------------------------------





