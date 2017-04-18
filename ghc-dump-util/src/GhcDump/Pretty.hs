{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE FlexibleInstances #-}
{-# OPTIONS_GHC -fno-warn-orphans #-}

module GhcDump.Pretty
    ( Pretty(..)
    , module GhcDump.Pretty
    ) where

import GhcDump.Ast
import GhcDump.Util
import qualified Data.Text as T
import Text.PrettyPrint.ANSI.Leijen

data PrettyOpts = PrettyOpts { showUniques :: Bool
                             , showIdInfo :: Bool
                             , showLetTypes :: Bool
                             }

defaultPrettyOpts :: PrettyOpts
defaultPrettyOpts = PrettyOpts { showUniques = False
                               , showIdInfo  = False
                               , showLetTypes  = False
                               }

-- orphan
instance Pretty T.Text where
    pretty = text . T.unpack

instance Pretty ExternalName where
    pretty n@ExternalName{} = pretty (externalModuleName n) <> "." <> text (T.unpack $ externalName n)
    pretty ForeignCall = "<foreign>"

instance Pretty ModuleName where
    pretty = text . T.unpack . getModuleName

instance Pretty Unique where
    pretty = text . show

instance Pretty BinderId where
    pretty (BinderId b) = pretty b

instance Pretty Binder where
    pretty = pprBinder defaultPrettyOpts

pprBinder :: PrettyOpts -> Binder -> Doc
pprBinder opts (Bndr b)
  | showUniques opts = pretty (binderName b) <> "_" <> pretty (binderId b)
  | otherwise        = pretty (binderName b)

instance Pretty TyCon where
    pretty (TyCon t _) = text $ T.unpack t

instance Pretty Lit where
    pretty SomeLit = text "LIT"

instance Pretty CoreStats where
    pretty c =
        "Core Size"
        <>braces (hsep [ "terms="<>int (csTerms c)
                       , "types="<>int (csTypes c)
                       , "cos="<>int (csCoercions c)
                       , "vbinds="<>int (csValBinds c)
                       , "jbinds="<>int (csJoinBinds c)
                       ])

pprIdInfo :: PrettyOpts -> IdInfo -> IdDetails -> Doc
pprIdInfo opts i d
  | not $ showIdInfo opts = empty
  | otherwise = comment $ "IdInfo:" <+> align doc
  where
    doc = sep $ punctuate ", "
          $ [ pretty d
            , "arity=" <> pretty (idiArity i)
            , "occ=" <> pretty (idiOccInfo i)
            , "str=" <> pretty (idiStrictnessSig i)
            , "dmd=" <> pretty (idiDemandSig i)
            , "call-arity=" <> pretty (idiCallArity i)
            ] ++ (if idiIsOneShot i then ["one-shot"] else [])

instance Pretty OccInfo where
    pretty OccManyOccs = "Many"
    pretty OccDead = "Dead"
    pretty OccOneOcc = "One"
    pretty (OccLoopBreaker strong) =
        if strong then "Strong Loopbrk" else "Weak Loopbrk"

instance Pretty IdDetails where
    pretty = text . show

data TyPrec   -- See Note [Precedence in types] in TyCoRep.hs
  = TopPrec         -- No parens
  | FunPrec         -- Function args; no parens for tycon apps
  | TyOpPrec        -- Infix operator
  | TyConPrec       -- Tycon args; no parens for atomic
  deriving( Eq, Ord )

pprType :: PrettyOpts -> Type -> Doc
pprType opts = pprType' opts TopPrec

pprType' :: PrettyOpts -> TyPrec -> Type -> Doc
pprType' opts _ (VarTy b)         = pprBinder opts b
pprType' opts p t@(FunTy _ _)     = maybeParens (p >= FunPrec) $ hsep $ punctuate " ->" (map (pprType' opts FunPrec) (splitFunTys t))
pprType' opts p (TyConApp tc [])  = pretty tc
pprType' opts p (TyConApp tc tys) = maybeParens (p >= TyConPrec) $ pretty tc <+> hsep (map (pprType' opts TyConPrec) tys)
pprType' opts p (AppTy a b)       = maybeParens (p >= TyConPrec) $ pprType' opts TyConPrec a <+> pprType' opts TyConPrec b
pprType' opts p t@(ForAllTy _ _)  = let (bs, t') = splitForAlls t
                                    in maybeParens (p >= TyOpPrec)
                                       $ "forall" <+> hsep (map (pprBinder opts) bs) <> "." <+> pprType opts t'
pprType' opts _ LitTy             = "LIT"
pprType' opts _ CoercionTy        = "Co"

maybeParens :: Bool -> Doc -> Doc
maybeParens True  = parens
maybeParens False = id

instance Pretty Type where
    pretty = pprType defaultPrettyOpts

pprExpr :: PrettyOpts -> Expr -> Doc
pprExpr opts = pprExpr' opts False

pprExpr' :: PrettyOpts -> Bool -> Expr -> Doc
pprExpr' opts _parens (EVar v)         = pretty v
pprExpr' opts _parens (EVarGlobal v)   = pretty v
pprExpr' opts _parens (ELit l)         = pretty l
pprExpr' opts parens  (EApp x ys)      = maybeParens parens $ hang' (pprExpr' opts True x) 2 (sep $ map pprArg ys)
  where pprArg (EType t) = char '@' <> pprType' opts TyConPrec t
        pprArg x         = pprExpr' opts True x
pprExpr' opts parens  x@(ETyLam _ _)   = let (bs, x') = collectTyBinders x
                                         in maybeParens parens
                                            $ hang' ("Λ" <+> sep (map pretty bs) <+> smallRArrow) 2 (pprExpr' opts False x')
pprExpr' opts parens  x@(ELam _ _)     = let (bs, x') = collectBinders x
                                         in maybeParens parens
                                            $ hang' ("λ" <+> sep (map pretty bs) <+> smallRArrow) 2 (pprExpr' opts False x')
pprExpr' opts parens  (ELet xs y)      = maybeParens parens $ "let" <+> (align $ vcat $ map (uncurry (pprBinding opts)) xs)
                                         <$$> "in" <+> align (pprExpr' opts False y)
  where pprBind (b, rhs) = pretty b <+> equals <+> align (pprExpr' opts False rhs)
pprExpr' opts parens  (ECase x b alts) = maybeParens parens
                                         $ sep [ sep [ "case" <+> pprExpr' opts False x
                                                     , "of" <+> pretty b <+> "{" ]
                                               , indent 2 $ vcat $ map pprAlt alts
                                               , "}"
                                               ]
  where pprAlt (Alt con bndrs rhs) = hang' (hsep (pretty con : map pretty bndrs) <+> smallRArrow) 2 (pprExpr' opts False rhs)
pprExpr' opts parens  (EType t)        = maybeParens parens $ "TYPE:" <+> pprType opts t
pprExpr' opts parens  ECoercion        = "CO"

instance Pretty AltCon where
    pretty (AltDataCon t) = text $ T.unpack t
    pretty (AltLit l) = pretty l
    pretty AltDefault = text "DEFAULT"

instance Pretty Expr where
    pretty = pprExpr defaultPrettyOpts

pprTopBinding :: PrettyOpts -> TopBinding -> Doc
pprTopBinding opts tb =
    case tb of
      NonRecTopBinding b s rhs -> pprTopBind (b,s,rhs)
      RecTopBinding bs -> "rec" <+> braces (line <> vsep (map pprTopBind bs))
  where
    pprTopBind (b@(Bndr b'),s,rhs) =
        pprBinder opts b <+> dcolon <+> pprType opts (binderType b')
        <$$> pprIdInfo opts (binderIdInfo b') (binderIdDetails b')
        <$$> comment (pretty s)
        <$$> hang' (pprBinder opts b <+> equals) 2 (pprExpr opts rhs)
        <> line

pprBinding :: PrettyOpts -> Binder -> Expr -> Doc
pprBinding opts b@(Bndr b') rhs =
    ppWhen (showLetTypes opts) (pprBinder opts b <+> dcolon <+> pprType opts (binderType b'))
    <$$> pprIdInfo opts (binderIdInfo b') (binderIdDetails b')
    <$$> hang' (pprBinder opts b <+> equals) 2 (pprExpr opts rhs)

instance Pretty TopBinding where
    pretty = pprTopBinding defaultPrettyOpts

pprModule :: PrettyOpts -> Module -> Doc
pprModule opts m =
    comment (pretty $ modulePhase m)
    <$$> text "module" <+> pretty (moduleName m) <+> "where" <> line
    <$$> vsep (map (pprTopBinding opts) (moduleTopBindings m))

instance Pretty Module where
    pretty = pprModule defaultPrettyOpts

comment :: Doc -> Doc
comment x = "{-" <+> x <+> "-}"

dcolon :: Doc
dcolon = "::"

smallRArrow :: Doc
smallRArrow = "→"

hang' :: Doc -> Int -> Doc -> Doc
hang' d1 n d2 = hang n $ sep [d1, d2]

ppWhen :: Bool -> Doc -> Doc
ppWhen True x = x
ppWhen False _ = empty
