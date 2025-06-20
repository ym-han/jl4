module L4.Evaluate.Value where

import Base
import L4.Syntax
import L4.Evaluate.ValueLazy (UnaryBuiltinFun(..))
import L4.Evaluate.Operators (BinOp)

type Environment = Map Unique Value

data Value =
    ValNumber Rational -- for now
  | ValString Text
  | ValList [Value]
  | ValClosure (GivenSig Resolved) (Expr Resolved) Environment
  | ValUnaryBuiltinFun UnaryBuiltinFun
  | ValBinaryBuiltinFun BinOp
  | ValUnappliedConstructor Resolved
  | ValConstructor Resolved [Value]
  | ValAssumed Resolved
  -- | ValEnvironment Environment
  deriving stock (Show)

-- | This is a non-standard instance because environments can be recursive, hence we must
-- not actually force the environments ...
--
instance NFData Value where
  rnf :: Value -> ()
  rnf (ValNumber i)               = rnf i
  rnf (ValString t)               = rnf t
  rnf (ValList vs)                = rnf vs
  rnf (ValClosure given expr env) = env `seq` rnf given `seq` rnf expr
  rnf (ValUnaryBuiltinFun r)      = rnf r
  rnf (ValBinaryBuiltinFun r)     = rnf r
  rnf (ValUnappliedConstructor r) = rnf r
  rnf (ValConstructor r vs)       = rnf r `seq` rnf vs
  rnf (ValAssumed r)              = rnf r
  -- rnf (ValEnvironment env)        = env `seq` ()
