{-# LANGUAGE CPP                 #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE PatternGuards       #-}
{-# LANGUAGE BangPatterns        #-}

module Agda.TypeChecking.Reduce.Fast
  ( fastReduce ) where

import Control.Applicative
import Control.Monad.Reader

import Data.List
import qualified Data.Map as Map
import Data.Traversable (traverse)

import Agda.Syntax.Internal
import Agda.Syntax.Common
import Agda.Syntax.Position
import Agda.Syntax.Literal

import Agda.TypeChecking.CompiledClause
import Agda.TypeChecking.Monad
import Agda.TypeChecking.Pretty
import Agda.TypeChecking.Reduce as R
import Agda.TypeChecking.Reduce.Monad as RedM
import Agda.TypeChecking.Substitute
import Agda.TypeChecking.Monad.Builtin hiding (constructorForm)
import Agda.TypeChecking.CompiledClause.Match

import Agda.Utils.Maybe
import Agda.Utils.Memo

#include "undefined.h"
import Agda.Utils.Impossible

data CompactDef =
  CompactDef { cdefDelayed        :: Bool
             , cdefNonterminating :: Bool
             , cdefDef            :: CompactDefn }

data CompactDefn
  = CFun  { cfunCompiled  :: CompiledClauses }
  | CCon  { cconSrcCon    :: ConHead }
  | COther

compactDef :: Definition -> ReduceM CompactDef
compactDef def = do
  cdefn <-
    case theDef def of
      Constructor{conSrcCon = c} -> pure CCon{cconSrcCon = c}
      Function{funCompiled = Just cc, funClauses = _:_} ->
        pure CFun{ cfunCompiled = cc }
      _ -> pure COther
  return $
    CompactDef { cdefDelayed        = defDelayed def == Delayed
               , cdefNonterminating = defNonterminating def
               , cdefDef            = cdefn
               }

-- | First argument: allow non-terminating reductions.
fastReduce :: Bool -> Term -> ReduceM (Blocked Term)
fastReduce allowNonTerminating v = do
  let name (Con c _) = c
      name _         = __IMPOSSIBLE__
  z <- fmap name <$> getBuiltin' builtinZero
  s <- fmap name <$> getBuiltin' builtinSuc
  constInfo <- unKleisli (compactDef <=< getConstInfo)
  ReduceM $ \ env -> reduceTm env (memoUnsafe constInfo) allowNonTerminating z s v

unKleisli :: (a -> ReduceM b) -> ReduceM (a -> b)
unKleisli f = ReduceM $ \ env x -> unReduceM (f x) env

reduceTm :: ReduceEnv -> (QName -> CompactDef) -> Bool -> Maybe ConHead -> Maybe ConHead -> Term -> Blocked Term
reduceTm env !constInfo allowNonTerminating zero suc = reduceB'
  where
    runReduce m = unReduceM m env
    reduceB' v =
      case v of
        Def f es -> unfoldDefinitionE False reduceB' (Def f []) f es
        Con c vs ->
          -- Constructors can reduce' when they come from an
          -- instantiated module.
          case unfoldDefinition False reduceB' (Con c []) (conName c) vs of
            NotBlocked r v -> NotBlocked r $ reduceNat v
            b              -> b
        Lit{} -> done
        Var{} -> done
        _     -> runReduce (slowReduceTerm v)
      where
        done = notBlocked v

        reduceNat v@(Con c [])
          | Just c == zero = Lit $ LitNat (getRange c) 0
        reduceNat v@(Con c [a])
          | Just c == suc  = inc . ignoreBlocking $ reduceB' (unArg a)
          where
            inc (Lit (LitNat r n)) = Lit (LitNat noRange $ n + 1)
            inc w                  = Con c [defaultArg w]
        reduceNat v = v

    -- Andreas, 2013-03-20 recursive invokations of unfoldCorecursion
    -- need also to instantiate metas, see Issue 826.
    unfoldCorecursionE :: Elim -> Blocked Elim
    unfoldCorecursionE e@Proj{}             = notBlocked e
    unfoldCorecursionE (Apply (Arg info v)) = fmap (Apply . Arg info) $
      unfoldCorecursion v

    unfoldCorecursion :: Term -> Blocked Term
    unfoldCorecursion (Def f es) = unfoldDefinitionE True unfoldCorecursion (Def f []) f es
    unfoldCorecursion v          = reduceB' v

    -- | If the first argument is 'True', then a single delayed clause may
    -- be unfolded.
    unfoldDefinition ::
      Bool -> (Term -> Blocked Term) ->
      Term -> QName -> Args -> Blocked Term
    unfoldDefinition unfoldDelayed keepGoing v f args =
      unfoldDefinitionE unfoldDelayed keepGoing v f (map Apply args)

    unfoldDefinitionE ::
      Bool -> (Term -> Blocked Term) ->
      Term -> QName -> Elims -> Blocked Term
    unfoldDefinitionE unfoldDelayed keepGoing v f es =
      case unfoldDefinitionStep unfoldDelayed (constInfo f) v f es of
        NoReduction v    -> v
        YesReduction _ v -> keepGoing v

    unfoldDefinitionStep :: Bool -> CompactDef -> Term -> QName -> Elims -> Reduced (Blocked Term) Term
    unfoldDefinitionStep unfoldDelayed CompactDef{cdefDelayed = delayed, cdefNonterminating = nonterm, cdefDef = def} v0 f es =
      let v = v0 `applyE` es
          -- Non-terminating functions
          -- (i.e., those that failed the termination check)
          -- and delayed definitions
          -- are not unfolded unless explicitely permitted.
          dontUnfold =
               (not allowNonTerminating && nonterm)
            || (not unfoldDelayed       && delayed)
      in case def of
        CCon{cconSrcCon = c} ->
          noReduction $ notBlocked $ Con c [] `applyE` es
        CFun{cfunCompiled = cc} ->
          reduceNormalE v0 f (map notReduced es) dontUnfold cc
        _ -> runReduce $ R.unfoldDefinitionStep unfoldDelayed v0 f es
      where
        noReduction    = NoReduction
        yesReduction s = YesReduction s

        reduceNormalE :: Term -> QName -> [MaybeReduced Elim] -> Bool -> CompiledClauses -> Reduced (Blocked Term) Term
        reduceNormalE v0 f es dontUnfold cc
          | dontUnfold = defaultResult  -- non-terminating or delayed
          | otherwise  = appDefE f v0 cc es
          where defaultResult = noReduction $ NotBlocked AbsurdMatch vfull
                vfull         = v0 `applyE` map ignoreReduced es

        appDefE :: QName -> Term -> CompiledClauses -> MaybeReducedElims -> Reduced (Blocked Term) Term
        appDefE f v cc es =
          case match' f [(cc, es, id)] of
            YesReduction s u -> YesReduction s u
            NoReduction es'  -> NoReduction $ applyE v <$> es'

        match' :: QName -> Stack -> Reduced (Blocked Elims) Term
        match' f ((c, es, patch) : stack) =
          let no blocking es = NoReduction $ blocking $ patch $ map ignoreReduced es
              yes t          = YesReduction NoSimplification t

          in case c of

            -- impossible case
            Fail -> no (NotBlocked AbsurdMatch) es

            -- done matching
            Done xs t
              -- if the function was partially applied, return a lambda
              | m < n     -> yes $ applySubst (toSubst es) $ foldr lam t (drop m xs)
              -- otherwise, just apply instantiation to body
              -- apply the result to any extra arguments
              | m == n    -> {-# SCC match'Done #-} yes $ applySubst (toSubst es) t
              | otherwise -> yes $ applySubst (toSubst es0) t `applyE` map ignoreReduced es1
              where
                n          = length xs
                m          = length es
                -- at least the first @n@ elims must be @Apply@s, so we can
                -- turn them into a subsitution
                toSubst    = parallelS . reverse . map (unArg . argFromElim . ignoreReduced)
                (es0, es1) = splitAt n es
                lam x t    = Lam (argInfo x) (Abs (unArg x) t)

            -- splitting on the @n@th elimination
            Case (Arg _ n) bs ->
              case splitAt n es of
                -- if the @n@th elimination is not supplied, no match
                (_, []) -> no (NotBlocked Underapplied) es
                -- if the @n@th elimination is @e0@
                (es0, MaybeRed red e0 : es1) ->
                  -- get the reduced form of @e0@
                  let eb :: Blocked Elim =
                        case red of
                          Reduced b  -> e0 <$ b
                          NotReduced -> unfoldCorecursionE e0
                      e = ignoreBlocking eb
                      -- replace the @n@th argument by its reduced form
                      es' = es0 ++ [MaybeRed red e] ++ es1
                      -- if a catch-all clause exists, put it on the stack
                      catchAllFrame stack = maybe stack (\c -> (c, es', patch) : stack) (catchAllBranch bs)
                      -- If our argument is @Lit l@, we push @litFrame l@ onto the stack.
                      litFrame l stack =
                        case Map.lookup l (litBranches bs) of
                          Nothing -> stack
                          Just cc -> (cc, es0 ++ es1, patchLit) : stack
                      -- If our argument (or its constructor form) is @Con c vs@
                      -- we push @conFrame c vs@ onto the stack.
                      conFrame c vs stack =
                        case Map.lookup (conName c) (conBranches bs) of
                          Nothing -> stack
                          Just cc -> ( content cc
                                     , es0 ++ map (MaybeRed red . Apply) vs ++ es1
                                     , patchCon c (length vs)
                                     ) : stack
                      -- If our argument is @Proj p@, we push @projFrame p@ onto the stack.
                      projFrame p stack =
                        case Map.lookup p (conBranches bs) of
                          Nothing -> stack
                          Just cc -> (content cc, es0 ++ es1, patchLit) : stack
                      -- The new patch function restores the @n@th argument to @v@:
                      -- In case we matched a literal, just put @v@ back.
                      patchLit es = patch (es0 ++ [e] ++ es1)
                        where (es0, es1) = splitAt n es
                      -- In case we matched constructor @c@ with @m@ arguments,
                      -- contract these @m@ arguments @vs@ to @Con c vs@.
                      patchCon c m es = patch (es0 ++ [Con c vs <$ e] ++ es2)
                        where (es0, rest) = splitAt n es
                              (es1, es2)  = splitAt m rest
                              vs          = map argFromElim es1
                  -- Now do the matching on the @n@ths argument:
                  in
                   case fmap ignoreSharing <$> eb of
                    Blocked x _            -> no (Blocked x) es'
                    NotBlocked _ (Apply (Arg info (MetaV x _))) -> no (Blocked x) es'

                    -- In case of a natural number literal, try also its constructor form
                    NotBlocked _ (Apply (Arg info v@(Lit l@(LitNat r n)))) ->
                      let cFrame stack
                            | n == 0, Just z <- zero = conFrame z [] stack
                            | n > 0,  Just s <- suc  = conFrame s [Arg info (Lit (LitNat r (n - 1)))] stack
                            | otherwise              = stack
                      in match' f $ litFrame l $ cFrame $ catchAllFrame stack

                    NotBlocked _ (Apply (Arg info v@(Lit l))) ->
                      match' f $ litFrame l $ catchAllFrame stack

                    -- In case of a constructor, push the conFrame
                    NotBlocked _ (Apply (Arg info (Con c vs))) ->
                      match' f $ conFrame c vs $ catchAllFrame $ stack

                    -- In case of a projection, push the projFrame
                    NotBlocked _ (Proj _ p) ->
                      match' f $ projFrame p $ stack -- catchAllFrame $ stack
                      -- Issue #1986: no catch-all for copattern matching!

                    -- Otherwise, we are stuck.  If we were stuck before,
                    -- we keep the old reason, otherwise we give reason StuckOn here.
                    NotBlocked blocked e -> no (NotBlocked $ stuckOn e blocked) es'

        -- If we reach the empty stack, then pattern matching was incomplete
        match' f [] = {- new line here since __IMPOSSIBLE__ does not like the ' in match' -}
          runReduce $
            traceSLn "impossible" 10
              ("Incomplete pattern matching when applying " ++ show f)
              __IMPOSSIBLE__
