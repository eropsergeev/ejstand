{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE QuasiQuotes #-}
module EjStand.Internals.ADTReader
    ( mkADTReader
    )
where

import           Data.Maybe                     ( fromMaybe )
import           Data.String                    ( IsString
                                                , fromString
                                                )
import           Data.Map.Strict                ( (!?) )
import qualified Data.Map.Strict               as Map
import           Language.Haskell.TH

getConstructors :: Name -> Q [Con]
getConstructors name = do
    info <- reify name
    let errorMsg = "ADTReader: Unable to get constructors from non-plain ADT"
    return . fromMaybe (fail errorMsg) $ case info of
        TyConI dec -> case dec of
            DataD _ _ _ _ cons _ -> Just cons
            _                    -> Nothing
        _ -> Nothing

mkReaderTuple :: Con -> Q Exp
mkReaderTuple (NormalC name []) =
    let leftStr = LitE . StringL . nameBase $ name
        left    = AppE (UnboundVarE 'fromString) leftStr
        right   = ConE name
    in  return $ TupE [left, right]
mkReaderTuple _ = fail "ADTReader: Either not a normal constructor presented or it has additional arguments"

mkReaderList :: [Con] -> Q Exp
mkReaderList cons = ListE <$> mapM mkReaderTuple cons

mkReaderMap :: [Con] -> Q Exp
mkReaderMap cons = AppE (VarE 'Map.fromList) <$> mkReaderList cons

-- Represents the type:
--   (IsString s, Ord s) => s -> ADT
mkADTReaderType :: Name -> Q Type
mkADTReaderType adt = do
    keyTypeName <- VarT <$> newName "s"
    let context = (`AppT` keyTypeName) . ConT <$> [''IsString, ''Ord]
        type'   = ArrowT `AppT` keyTypeName `AppT` (ConT ''Maybe `AppT` ConT adt)
    return $ ForallT [] context type'

mkADTReader :: Name -> String -> Q [Dec]
mkADTReader adt readerName = do
    cons <- getConstructors adt
    rMap <- mkReaderMap cons
    let name = mkName readerName
    lookupF <- [| (!?) |]
    let right = AppE lookupF rMap
    type_ <- mkADTReaderType adt
    return [SigD name type_, FunD name [Clause [] (NormalB right) []]]