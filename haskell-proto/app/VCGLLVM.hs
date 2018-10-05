{-# LANGUAGE DataKinds #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE StandaloneDeriving #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE TypeOperators #-}
{-# LANGUAGE TypeSynonymInstances #-}
{-# LANGUAGE UndecidableInstances #-}
module VCGLLVM
  ( getLLVMMod
  , inject
  , bb2SMT
  , getDefineByName
  , events
  , LState
  , locals
  , getFunctionNameFromValSymbol
  , LEvent(..)
  , ppEvent
  , argVar
  ) where

import           Control.Monad.State
import           Data.Bits
import           Data.Int
import           Data.LLVM.BitCode
import qualified Data.List as List
import qualified Data.Map as Map
import           Data.Text (Text)
import qualified Data.Text as Text
import qualified Data.Text.Lazy.Builder as Builder
import           GHC.Stack
import           Text.LLVM hiding ((:>))
import qualified What4.Protocol.SMTLib2.Syntax as SMT

import VCGCommon

type Locals = Map.Map Ident SMT.Term

data LEvent
  = CmdEvent !SMT.Command
  | AllocaEvent !Ident !SMT.Term !Integer !Var
    -- ^ `AllocaEvent nm w align v` indicates that we should allocate `w` bytes on the stack
    -- and assign the address to `v`.
    --
    -- The address should be a multiple of `align`.
    --
    -- The identifier is stored so that we can uniquely refer to this identifier.
  | LoadEvent !SMT.Term !Integer !Var
    -- ^ `LoadEvent a w v` indicates that we read `w` bytes from address `a`,
    -- and the value should be assigned to `v` in the SMTLIB.
    --
    -- The variable is a bitvector with width @8*w@.
  | StoreEvent !SMT.Term !Integer !SMT.Term
    -- ^ `StoreEvent a w v` indicates that we write the `w` byte value `v` to `a`.
  | InvokeEvent !Bool !SMT.Term [SMT.Term] (Maybe (Ident, Var))
    -- ^ The invoke event takes the address of the function that we are jumping to, the
    -- arguments that are passed in, and the return identifier and variable to assign the return value to
    -- (if any).
  | BranchEvent !SMT.Term !BlockLabel !BlockLabel
    -- ^ Branch event with the predicate being branched on, and the label of the true and false blocks.
  | JumpEvent !BlockLabel
    -- ^ Jump evebnt with the label that we are jumping to.
  | ReturnEvent !(Maybe SMT.Term)
    -- ^ Return with the value being returned.

ppEvent :: LEvent
        -> String
ppEvent CmdEvent{} = "cmd"
ppEvent AllocaEvent{} = "alloca"
ppEvent LoadEvent{} = "load"
ppEvent StoreEvent{} = "store"
ppEvent (InvokeEvent _ _ _ _) = "invoke"
ppEvent (BranchEvent _ _ _) = "branch"
ppEvent (JumpEvent _) = "jump"
ppEvent (ReturnEvent _) = "return"

-- TODO: add a predicate to distinguish stack address and heap address
-- TODO: arbitray size read/write to memory
data LState = LState
  { locals    :: !Locals
  , disjoint  :: ![(SMT.Term, SMT.Term)]
  , events    :: ![LEvent]
  }

type LStateM a = StateT LState IO a

addEvent :: LEvent -> LStateM ()
addEvent e = modify $ \s -> s { events = e:events s }

addCommand :: SMT.Command -> LStateM ()
addCommand cmd = addEvent (CmdEvent cmd)

byteCount :: Type
          -> Integer
byteCount (PrimType (Integer  w))
  | w > 0
  , (w `mod` 8) == 0 =
    toInteger (w `div` 8)
byteCount (PtrTo _) = 8
byteCount tp = do
  error $ "byteCount: unsupported type " ++ show tp


readMem :: SMem
        -> SMT.Term -- ^ Address to read
        -> Type
        -> SMT.Term
readMem mem ptr (PrimType (Integer  w))
  | w > 0
  , (w `mod` 8) == 0 = readBVLE mem ptr (toInteger (w `div` 8))
readMem mem ptr (PtrTo _) = readBVLE mem ptr 8
readMem _ _ tp = do
  error $ "readMem: unsupported type " ++ show tp

memVar :: Integer -> Text
memVar i = "llvmmem_" <> Text.pack (show i)

identVar :: Ident -> Text
identVar (Ident nm) = "llvm_" <> Text.pack nm

argVar :: Typed Ident -> Text
argVar (Typed _ (Ident arg)) = "llvmarg_" <> Text.pack arg

-- Inject initial (symbolic) arguments
-- The [String] are arugment name used for this function
inject :: [(Ident,SMT.Term)] -> LState
inject args = do
  let cmd = SMT.declareFun (memVar 0) [] memType
   in LState { locals = Map.fromList args
             , disjoint = []
             , events = [CmdEvent cmd]
             }

localsUpdate :: Ident -> SMT.Term -> LStateM ()
localsUpdate key val = do
  modify $ \s -> s { locals = Map.insert key val (locals s) }

addDisjointPtr :: SMT.Term -> SMT.Term -> LStateM ()
addDisjointPtr base sz = do
  let end = SMT.bvadd base [sz]
  l <- gets disjoint
  forM_ l $ \(prevBase, prevEnd) -> do
    -- Assert [base,end) is before or after [prevBase, prevEnd)
    addCommand $ SMT.assert $ SMT.or [SMT.bvule prevEnd base, SMT.bvule end prevBase]
  modify $ \s -> s { disjoint = (base,end):disjoint s }

llvmError :: String -> a
llvmError msg = error ("[LLVM Error] " ++ msg)

arithOpFunc :: ArithOp
            -> SMT.Term
            -> SMT.Term
            -> SMT.Term
arithOpFunc (Add _uw _sw) x y = SMT.bvadd x [y]
arithOpFunc (Sub _uw _sw) x y = SMT.bvsub x y
arithOpFunc (Mul _uw _sw) x y = SMT.bvmul x [y]
arithOpFunc _ _ _ = llvmError "Not implemented yet"

asSMTType :: Type -> Maybe SMT.Type
asSMTType (PtrTo _) = Just (SMT.bvType 64)
asSMTType (PrimType (Integer i)) | i > 0 = Just $ SMT.bvType (toInteger i)
asSMTType _ = Nothing

primEval :: Type
         -> Value
         -> LStateM SMT.Term
primEval _ (ValIdent var@(Ident nm)) = do
  lcls <- gets $ locals
  case Map.lookup var lcls of
    Nothing ->
      llvmError  $ "Not contained in the locals: " ++ nm
    Just v ->
      pure v
primEval (PrimType (Integer w)) (ValInteger i) | w > 0 = do
  pure $ SMT.bvdecimal i (toInteger w)
primEval _ _ = error "TODO: Add more support in primEval"

evalTyped :: Typed Value -> LStateM SMT.Term
evalTyped (Typed tp var) = primEval tp var

defineTerm :: Ident -> SMT.Type -> SMT.Term -> LStateM ()
defineTerm nm tp t = do
  let vnm = identVar nm
  addCommand $ SMT.defineFun vnm [] tp t
  localsUpdate nm (SMT.T (Builder.fromText vnm))

setUndefined :: Ident -> SMT.Type -> LStateM Var
setUndefined ident tp = do
  let vnm = identVar ident
  localsUpdate ident (varTerm vnm)
  pure vnm

assign2SMT :: Ident -> Instr -> LStateM ()
assign2SMT ident (Arith op (Typed lty lhs) rhs)
  | Just tp <- asSMTType lty = do
      lhsv   <- primEval lty lhs
      rhsv   <- primEval lty rhs
      defineTerm ident tp $ arithOpFunc op lhsv rhsv

assign2SMT ident (ICmp op (Typed lty@(PrimType (Integer w)) lhs) rhs) = do
  lhsv <- primEval lty lhs
  rhsv <- primEval lty rhs
  let r =
        case op of
          Ieq -> SMT.eq [lhsv, rhsv]
          Ine -> SMT.distinct [lhsv, rhsv]
          Iugt -> SMT.bvugt lhsv rhsv
          Iuge -> SMT.bvuge lhsv rhsv
          Iult -> SMT.bvult lhsv rhsv
          Iule -> SMT.bvule lhsv rhsv
          Isgt -> SMT.bvsgt lhsv rhsv
          Isge -> SMT.bvsge lhsv rhsv
          Islt -> SMT.bvslt lhsv rhsv
          Isle -> SMT.bvsle lhsv rhsv
  defineTerm ident (SMT.bvType (toInteger w)) r
assign2SMT nm (Alloca ty eltCount malign) = do
  -- LLVM Size
  let eltSize :: Integer
      eltSize =
        case ty of
          PrimType (Integer i) | i .&. 0x7 == 0 -> toInteger i `shiftR` 3
          PtrTo _ -> 8
          _ -> error $ "Unexpected type " ++ show ty
  -- Total size as a bv64
  totalSize <-
    case eltCount of
      Nothing -> pure $ SMT.bvdecimal eltSize 64
      Just (Typed itp@(PrimType (Integer 64)) i) -> do
        cnt <- primEval itp i
        pure $ SMT.bvmul (SMT.bvdecimal eltSize 64) [cnt]
      Just (Typed itp _) -> do
        error $ "Unexpected count type " ++ show itp

  let base = identVar nm
  let align = case malign of
                Nothing -> 1
                Just a -> toInteger a
  addEvent $ AllocaEvent nm totalSize align base
{-
  addDisjointPtr (varTerm base) totalSize
  -- Add assertion about alignment.
  when (align /= 1) $ do
    addCommand $ SMT.assert $
      SMT.eq [SMT.bvand (varTerm base) [SMT.bvdecimal (toInteger a-1) 64], SMT.bvdecimal 0 64]
-}
  -- Assign base to local
  localsUpdate nm (varTerm base)
assign2SMT ident (Load (Typed (PtrTo lty) src) _ord _align) = do
  addrTerm <- primEval (PtrTo lty) src
  let w = byteCount lty
  let tp = case asSMTType lty of
             Just utp -> utp
             Nothing -> error $ "Unexpected type " ++ show lty
  valVar <- setUndefined ident tp
  addEvent $ LoadEvent addrTerm w valVar
assign2SMT ident (Call isTailCall retty f args) = do
  -- TODO: Add function called to invoke event.
  fPtrVal <- primEval (PrimType (Integer 64)) f
  argValues <- mapM evalTyped args
  case asSMTType retty of
    Just retType -> do
      returnVar <- setUndefined ident retType
      addCommand $ SMT.declareFun returnVar [] retType
      addEvent $ InvokeEvent isTailCall fPtrVal argValues (Just (ident, returnVar))
    Nothing -> do
      error $ "assign2SMT given unsupported return type"
assign2SMT _ instr  = do
  error $ "assign2SMT: unsupported instruction: " ++ show instr

effect2SMT :: HasCallStack => Instr -> LStateM ()
effect2SMT instr =
  case instr of
    Store llvmVal llvmPtr _align -> do
      addrTerm <- evalTyped llvmPtr
      valTerm  <- evalTyped llvmVal
      addEvent $ StoreEvent addrTerm (byteCount (typedType llvmVal)) valTerm
    Br (Typed _ty cnd) t1 t2 -> do
      cndTerm <- primEval (PrimType (Integer 1)) cnd
      addEvent $ BranchEvent (SMT.eq [cndTerm, SMT.bvdecimal 1 1]) t1 t2
    Jump t -> do
      addEvent $ JumpEvent t
    Ret (Typed llvmTy v) -> do
      val <- primEval llvmTy v
      addEvent $ ReturnEvent $ Just val
    RetVoid ->
      addEvent $ ReturnEvent Nothing
    _ -> error "Unsupported instruction."

stmt2SMT :: Stmt -> LStateM ()
stmt2SMT (Result ident inst _mds) = do
  assign2SMT ident inst
stmt2SMT (Effect instr _mds) = do
  effect2SMT instr

bb2SMT :: BasicBlock -> LStateM ()
bb2SMT bb = do
  mapM_ stmt2SMT (bbStmts bb)

getLLVMMod :: FilePath -> IO Module
getLLVMMod path = do
  res <- parseBitCodeFromFile path
  case res of
    Left err -> llvmError $ "Parse LLVM error: " ++ (show err)
    Right llvmMod -> return llvmMod

getDefineByName :: Module -> String -> Maybe Define
getDefineByName llvmMod name =
  List.find (\d -> defName d == Symbol name) (modDefines llvmMod)

getFunctionNameFromValSymbol :: Value' lab -> String
getFunctionNameFromValSymbol (ValSymbol (Symbol f)) = f
getFunctionNameFromValSymbol _ = error "Not directly a function"
