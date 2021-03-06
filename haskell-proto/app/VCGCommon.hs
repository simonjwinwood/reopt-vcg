{-# LANGUAGE DataKinds #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE TypeOperators #-}
module VCGCommon
  (  -- * SMT
    Var
  , varTerm
    -- * Memory
  , ptrSort
  , memSort
  , writeBVLE
    -- * Error reporting
  , warning
  , fatalError
  ) where

import           Data.Text (Text)
import qualified Data.Text.Lazy.Builder as Builder
import           System.Exit
import           System.IO
import qualified What4.Protocol.SMTLib2.Syntax as SMT

type Var = Text

varTerm :: Var -> SMT.Term
varTerm = SMT.T . Builder.fromText

-- | Sort for pointers
ptrSort :: SMT.Sort
ptrSort = SMT.bvSort 64

memSort :: SMT.Sort
memSort = SMT.arraySort ptrSort (SMT.bvSort 8)

-- | Read a number of bytes as a bitvector.
-- Note. This refers repeatedly to ptr so, it should be a constant.
writeBVLE :: SMT.Term
          -> SMT.Term  -- ^ Address to write
          -> SMT.Term  -- ^ Value to write
          -> Integer -- ^ Number of bytes to write.
          -> SMT.Term
writeBVLE mem ptr0 val w = go (w-1)
  where go :: Integer -> SMT.Term
        go 0 = SMT.store mem ptr0 (SMT.extract 7 0 val)
        go i =
          let ptr = SMT.bvadd ptr0 [SMT.bvdecimal i 64]
           in SMT.store (go (i-1)) ptr (SMT.extract (8*i+7) (8*i) val)


warning :: String -> IO ()
warning msg = do
  hPutStrLn stderr ("Warning: " ++ msg)

fatalError :: String -> IO a
fatalError msg = do
  hPutStrLn stderr msg
  exitFailure
