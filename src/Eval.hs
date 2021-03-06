{-# LANGUAGE FlexibleContexts  #-}
{-# LANGUAGE LambdaCase        #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TypeApplications  #-}
{-# LANGUAGE TypeOperators     #-}

module Eval where

import           Control.Algebra
import           Control.Carrier.Error.Either
import           Control.Carrier.State.Strict as S
import           Control.Carrier.Store
import           Control.Concurrent
import           Control.Concurrent.Chan
import           Control.Effect.State.Labelled
import           Control.Monad
import           Control.Monad.IO.Class
import           Data.IntMap as IntMap
import qualified Data.List as L
import           Data.Map as Map
import           Data.Maybe
import           Name
import           ScriptA.B
import           System.Directory
import           System.Random
import           Type

evaLit :: (Has (Env PAddr :+: Error EvalError) sig m,
           HasLabelled Store (Store PAddr Expr) sig m,
           MonadIO m)
       => Lit
       -> m Expr
evaLit = \case
  LitSymbol n -> do
    a <- lookupEnv n
    -- sendIO $ print (n, a)
    maybe (pure $ Elit $ LitSymbol n) fetch a
  LitObject ls -> do
    ls' <- forM (Map.toList ls) $ \(name, e) -> do
      e' <- evalExpr e
      return (name, e')
    pure $ Elit $ LitObject $ Map.fromList ls'
  LitArray arr -> Elit . LitArray <$> mapM evalExpr arr
  other -> pure $ Elit other

evalExpr :: (Has (Env PAddr :+: Error EvalError) sig m,
             HasLabelled Store (Store PAddr Expr) sig m,
             MonadIO m)
         => Expr
         -> m Expr
evalExpr = \case
  Exprs [] -> return (Elit LitNull)
  Exprs ls -> last <$> mapM evalExpr ls
  Break    -> throwError ControlBreak
  Continue -> throwError ControlContinue
  For e1 e2 e3 e4 -> do
    binds @PAddr [] $ do
      evalExpr e1
      let go val = do
            evalExpr e2 >>= \case
              Elit (LitBool True) -> do
                v3 <- evalExpr e3
                v4 <-
                  catchError @EvalError
                    (evalExpr e4)
                    ( \case
                        ControlContinue -> return (Elit LitNull)
                        e               -> throwError e
                    )
                go v4
              _                   -> return val

      catchError @EvalError
        (go (Elit LitNull))
        ( \case
            ControlBreak -> return (Elit LitNull)
            e            -> throwError e
        )
  IfElse a b c -> do
    evalExpr a >>= \case
      Elit (LitBool True)  -> evalExpr b
      Elit (LitBool False) -> evalExpr c
      _                    -> return (Elit LitNull)
  Return e -> evalExpr e >>= throwError . Control
  Var name v -> do
    a <- alloc name
    v' <- evalExpr v
    a .= v'
    varDec name a
    return v'
  While e1 e2 -> do
    let go = do
          evalExpr e1 >>= \case
            Elit (LitBool True) -> do
              catchError @EvalError
                (evalExpr e2)
                ( \case
                    ControlContinue -> return (Elit LitNull)
                    e               -> throwError e
                )
              go
            _ -> return ()
    catchError @EvalError
      go
      ( \case
          ControlBreak -> return ()
          e            -> throwError e
      )
    return (Elit LitNull)
  Elit   lit        -> evaLit lit
  Fun    names v    -> pure (Fun names v)
  AppFun v     args -> do
    evalExpr v >>= \case
      Fun names1 e -> do
        when (length names1 /= length args) (throwError ArgsNotMatch)
        eargs <- mapM evalExpr args
        addrs <- forM (zip names1 eargs) $ \(n, e) -> do
          n' <- alloc n
          n' .= e
          pure n'
        catchError @EvalError
          (binds (zip names1 addrs) (evalExpr e))
          ( \case
              Control ex -> return ex
              e          -> throwError e
          )
      BuildInFunction f -> do
        eargs <- mapM evalExpr args
        liftIO (f eargs) >>= \case
          Left e  -> throwError e
          Right v -> return v
      o -> throwError $ UnSpportAppFun (show (AppFun v args))
  Assignment name e -> do
    a <- lookupEnv name
    case a of
      Nothing -> evalExpr (Var name e)
      Just pa -> do
        e' <- evalExpr e
        pa .= e'
        return e'
  BuildInFunction f -> return (BuildInFunction f)
  Skip -> return Skip
  ObjectGet name ls -> do
    r1 <- case name of
      Name "this" -> evalExpr (Elit $ LitSymbol name)
      _ -> do
        a <- lookupEnv (Name "this")
        maybe (throwError $ VarNotDefined (show name)) (.= (Elit $ LitSymbol name)) a
        return (Elit $ LitSymbol name)
    case r1 of
      Elit (LitSymbol name') -> do
        evalExpr (Elit $ LitSymbol name') >>= \case
          p@(Elit (LitObject pairs)) -> case getFold ls p of
            Left ee  -> throwError ee
            Right ex -> return ex
          _ -> throwError (NotObject name')
      _ -> throwError ThisPointStrangeError
  ObjectSet name ls e -> do
    r1 <- case name of
      Name "this" -> evalExpr (Elit $ LitSymbol name)
      _ -> do
        a <- lookupEnv (Name "this")
        maybe (throwError $ VarNotDefined (show name)) (.= (Elit $ LitSymbol name)) a
        return (Elit $ LitSymbol name)
    case r1 of
      Elit (LitSymbol name') -> do
        evalExpr (Elit $ LitSymbol name') >>= \case
          p@(Elit (LitObject pairs)) -> do
            sv <- evalExpr e
            case setFold sv ls p of
              Left ee  -> throwError ee
              Right ex -> do
                a <- lookupEnv name'
                maybe (throwError $ VarNotDefined (show name)) (.= ex) a
                return ex
          _ -> throwError (NotObject name')
      _ -> throwError ThisPointStrangeError

setFold :: Expr
        -> [Name]
        -> Expr
        -> Either EvalError Expr
setFold sv [a] (Elit (LitObject pairs)) =
  return (Elit $ LitObject $ Map.insert a sv pairs)
setFold sv (a : ls) (Elit (LitObject pairs)) = do
  newExpr <- case Map.lookup a pairs of
    Nothing ->
      let go [x] = return $ Elit (LitObject (Map.fromList [(x, sv)]))
          go (x : xs) = do
            xs' <- go xs
            return $ Elit (LitObject (Map.fromList [(x, xs')]))
          go _ = Left ObjectSetError
       in go ls
    Just ex -> setFold sv ls ex
  return (Elit $ LitObject $ Map.insert a newExpr pairs)
setFold _ _ _ = Left ObjectSetError

getFold :: [Name]
        -> Expr
        -> Either EvalError Expr
getFold [] e = Right e
getFold (a : ls) (Elit (LitObject pairs)) =
  case Map.lookup a pairs of
    Nothing -> Left (ObjectNotF a)
    Just ex -> getFold ls ex
getFold (a : _) _ = Left (ObjectNotF a)

runEval :: Expr
        -> IO (Map Name PAddr, (PStore Expr, Either EvalError Expr))
runEval expr = do
  (a, (b, c)) <-
    runEnv
      . runStore
      . runError @EvalError
      $ evalExpr (init' expr)
  case c of
    Left ie  -> return (a, (b, Left $ StoreError ie))
    Right re -> return (a, (b, re))

add :: [Expr]
    -> IO (Either EvalError Expr)
add [Elit (LitNum b1), Elit (LitNum b2)] = return $ Right $ Elit $ LitNum (b1 + b2)
add ls = return $ Left $ AddTypeError ls

less :: [Expr]
     -> IO (Either EvalError Expr)
less [Elit (LitNum b1), Elit (LitNum b2)] = return $ Right $ Elit $ LitBool (b1 < b2)
less ls = return $ Left $ LessTypeError ls

logger :: [Expr] -> IO (Either EvalError Expr)
logger ls = print ls >> return (Right (head ls))

random' :: [Expr]
        -> IO (Either EvalError Expr)
random' [Elit (LitNum b1), Elit (LitNum b2)] = do
  v <- randomRIO (b1, b2)
  return $ Right $ Elit $ LitNum v
random' ls = return $ Left $ LessTypeError ls

skip' :: [Expr]
      -> IO (Either EvalError Expr)
skip' _ = return (Right Skip)

-- >>> runEval t
--  lit: LitSymbol (Name "<")
init' :: Expr -> Expr
init' e =
  Exprs $
    [ Var "+" $ BuildInFunction add,
      Var "<" $ BuildInFunction less,
      Var "logger" $ BuildInFunction logger,
      Var "random" $ BuildInFunction random',
      Var "skip" $ BuildInFunction skip',
      Var "this" $ Elit LitNull
    ]
      ++ [e]

runEval' :: Map Name PAddr
         -> IntMap (Maybe Expr)
         -> Expr
         -> IO (Either EvalError (IntMap (Maybe Expr), Map Name PAddr, Expr))
runEval' env store expr = do
  (resEnv, (PStore ps, resExpr)) <-
    runEnv' env
      . runStore' store
      . runError @EvalError
      $ evalExpr expr
  case resExpr of
    Left internalError -> return $ Left (StoreError internalError)
    Right evalResExpr  -> case evalResExpr of
      Left evalError   -> return $ Left evalError
      Right res -> do
        let ls  = Map.toList resEnv
            t   = Prelude.map (\(name, PAddr i) -> (i, join $ IntMap.lookup i ps)) ls
            nim = IntMap.fromList t
        return $ Right (nim, resEnv, res)

-- runEval :: Expr -> IO
-- test
test = do
  con <- readFile "test/script/objectPair.txt"
  case runCalc con of
    Left s  -> print s
    Right e -> do
      res <- runEval e
      print res
