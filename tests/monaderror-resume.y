{
{-# LANGUAGE FunctionalDependencies #-}
{-# LANGUAGE FlexibleInstances #-}
-- For ancient GHC 7.0.4
{-# LANGUAGE MultiParamTypeClasses #-}
module Main where

import Control.Monad (when)
import Data.Char
import System.Exit
}

%name parseStmts
%tokentype { Token }
%errorresumptive          -- the entire point of this test
%errorhandlertype explist -- as in monaderror-explist.y
%error { handleError }

%monad { ParseM } { (>>=) } { return }

%token
  '1' { TOne }
  '+' { TPlus }
  ';' { TSemi }

%%

Stmts : {- empty -}           { [] }
      | Stmt                  { [$1] }
      | Stmts ';' Stmt        { $1 ++ [$3] }
      | catch ';' Stmt %shift { [$3] } -- Could insert error AST token here in place of $1
      | catch                 { [] }   -- Catch-all at the end

Stmt : Exp { ExpStmt $1 }

Exp : '1'                { One }
    | Exp '+' Exp %shift { Plus $1 $3 }

{
data Token = TOne | TPlus | TSemi
  deriving (Eq,Show)

type Stmts = [Stmt]
data Stmt = ExpStmt Exp
  deriving (Eq, Show)
data Exp = One | Plus Exp Exp
  deriving (Eq, Show)

----------- Validation monad
data Validate e a = V e (Maybe a)
  deriving Functor
instance Monoid e => Applicative (Validate e) where
  pure a = V mempty (Just a)
  V e1 f <*> V e2 a = V (e1 <> e2) (f <*> a)
instance Monoid e => Monad (Validate e) where
  V e Nothing   >>= _ = V e Nothing -- fatal
  V e1 (Just a) >>= k | V e2 b <- k a = V (e1 <> e2) b -- non-fatal

abort :: Monoid e => Validate e a -- this would be mzero from MonadPlus
abort = V mempty Nothing

recordError :: e -> Validate e () -- this would be tell from MonadWriter
recordError e = V e (Just ())

runValidate (V e mb_a) = (e, mb_a)
-----------

type ParseM = Validate [ParseError]

data ParseError
        = ParseError [String]
    deriving Eq
instance Show ParseError where
  show (ParseError exp) = "Parse error. Expected: " ++ show exp

recordParseError :: [String] -> ParseM ()
recordParseError expected = recordError [ParseError expected]

handleError :: [Token] -> [String] -> ([Token] -> ParseM (Maybe a)) -> ParseM a
handleError ts expected resume = do
  recordParseError expected
  mb_ast <- resume ts
  case mb_ast of
    Just ast -> return ast
    Nothing  -> abort -- abort after parsing with no AST when resumption is impossible

lexer :: String -> [Token]
lexer [] = []
lexer (c:cs)
    | isSpace c = lexer cs
    | c == '1'  = TOne:(lexer cs)
    | c == '+'  = TPlus:(lexer cs)
    | c == ';'  = TSemi:(lexer cs)
    | otherwise = error "lexer error"

main :: IO ()
main = do
  test "1+1;1" $ \(_,mb_ast) -> mb_ast == Just [ExpStmt (One `Plus` One), ExpStmt One]
  test "1++1;1" $ \(errs,_) -> errs == [ParseError ["'1'"]]
  test "1++1;+" $ \(errs,_) -> errs == [ParseError ["'1'"], ParseError ["'1'"]]
  test "11;1" $ \(errs,_) -> errs == [ParseError []]
    -- urgh, `Exp -> '1' .` is purely a reduction action.
    -- We must walk the stack to get better messages
  test "11;++" $ \(errs,_) -> errs == [ParseError [], ParseError ["'1'"]]
    -- urgh, `Exp -> '1' .` is purely a reduction action.
    -- We must walk the stack to get better messages
  where
    test inp p = do
      putStrLn $ "testing " ++ inp
      let tokens = lexer inp
      let res = runValidate $ parseStmts tokens
      when (not (p res)) $ do
        print res
        exitWith (ExitFailure 1)
}
