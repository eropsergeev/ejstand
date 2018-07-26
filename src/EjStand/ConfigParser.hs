{-# LANGUAGE OverloadedStrings, BangPatterns #-}
module EjStand.ConfigParser
  ( parseStandingConfig
  , parseStandingConfigDirectory
  , parseGlobalConfiguration
  , retrieveGlobalConfiguration
  , retrieveGlobalConfiguration'
  )
where

import           EjStand.StandingModels         ( StandingConfig(..)
                                                , StandingOption(..)
                                                , GlobalConfiguration(..)
                                                , defaultGlobalConfiguration
                                                )
import           Data.Char                      ( isDigit
                                                , isLetter
                                                )
import           Data.Text.Encoding             ( decodeUtf8 )
import qualified Data.ByteString               as B
import           Data.Text                      ( Text
                                                , unpack
                                                )
import qualified Data.Text                     as Text
import           Data.Text.Read                 ( decimal )
import           Data.Time                      ( UTCTime
                                                , parseTimeM
                                                , defaultTimeLocale
                                                )
import qualified Data.List                     as List
import           Data.Set                       ( Set )
import qualified Data.Set                      as Set
import           Data.Map.Strict                ( Map
                                                , insertWith
                                                , (!?)
                                                )
import qualified Data.Map.Strict               as Map
import           Data.Maybe                     ( fromMaybe
                                                , listToMaybe
                                                )
import           Data.Ratio                     ( (%) )
import           Control.Exception              ( Exception
                                                , IOException
                                                , throw
                                                , catch
                                                )
import           Control.Applicative            ( liftA2 )
import           Control.Monad.State.Strict     ( State
                                                , get
                                                , put
                                                , evalState
                                                )
import           System.Directory               ( listDirectory )
import           Prelude                 hiding ( toInteger )

-- Character types

(|||) :: (a -> Bool) -> (a -> Bool) -> (a -> Bool)
(|||) = liftA2 (||)

isKeyCharacter :: Char -> Bool
isKeyCharacter = isDigit ||| isLetter ||| (== '_')

-- Exceptions

data ParsingException = NoValue Text
                      | UndefinedKey Text
                      | DuplicateKey Text
                      | TextValueExpected Text
                      | NestedConfigExpected Text
                      | IntegerExpected Text Text
                      | BoolExpected Text Text
                      | RationalExpected Text Text
                      | TimeExpected Text Text
                      | InvalidInterval Text
                      | UnexpectedKey Text

instance Exception ParsingException

instance Show ParsingException where
  show (NoValue key)                = "Value expected for key \"" ++ unpack key ++ "\", but got no = or {"
  show (UndefinedKey key)           = "No key \"" ++ unpack key ++ "\" found, but it's mandatory for a config"
  show (DuplicateKey key)           = "Key \"" ++ unpack key ++ "\" has multiple values, but must be unique"
  show (TextValueExpected key)      = "Text value at key \"" ++ unpack key ++ "\" expected, but other type of value found"
  show (NestedConfigExpected key)   = "Nested configuration at key \"" ++ unpack key ++ "\" expected, but other type of value found"
  show (IntegerExpected key value)  = "Integer expected, but \"" ++ unpack value ++ "\" got while parsing value of key \"" ++ unpack key ++ "\""
  show (BoolExpected key value)     = "Bool expected, but \"" ++ unpack value ++ "\" got while parsing value of key \"" ++ unpack key ++ "\""
  show (RationalExpected key value) = "Rational expected, but \"" ++ unpack value ++ "\" got while parsing value of key \"" ++ unpack key ++ "\""
  show (TimeExpected key value)     = "Time expected, but \"" ++ unpack value ++ "\" got while parsing value of key \"" ++ unpack key ++ "\""
  show (InvalidInterval key)        = "Invalid interval on key \"" ++ unpack key ++ "\""
  show (UnexpectedKey key)          = "Unexpected key \"" ++ unpack key ++ "\""

-- Internal representation of configuration tree

data ConfigValue = TextValue Text
                 | NestedConfig Configuration
                 deriving (Show)

type Configuration = Map Text [ConfigValue]

type ParsingState = State [Text]

-- Configuration parser

takeOneIf :: (Char -> Bool) -> Text -> (Text, Text)
takeOneIf pred str = case Text.uncons str of
  Nothing     -> ("", str)
  Just (c, t) -> if pred c then (Text.singleton c, t) else ("", str)

splitKeyValue :: Text -> (Text, Text, Text)
splitKeyValue str = (key, symbol, content)
 where
  (key   , str' ) = Text.span isLetter str
  (symbol, str'') = takeOneIf ((== '=') ||| (== '{')) $ Text.stripStart str'
  content         = Text.stripStart str''

buildConfig' :: Configuration -> ParsingState Configuration
buildConfig' cfg = do
  buffer <- get
  case buffer of
    []      -> return cfg
    (h : t) -> do
      put t
      if h == "}"
        then return cfg
        else do
          let (key, symbol, content) = splitKeyValue h
          new_elem <- case symbol of
            "=" -> return [TextValue content]
            "{" -> return . NestedConfig <$> buildConfig' Map.empty
            _   -> throw $ NoValue key
          buildConfig' $ insertWith (++) key new_elem cfg

removeComment :: Text -> Text
removeComment = fst . Text.breakOn "--"

buildConfig :: Text -> Configuration
buildConfig =
  evalState (buildConfig' Map.empty)
    . filter (not . Text.null)
    . map (Text.stripEnd . removeComment . Text.strip)
    . Text.lines

-- Traversing configuration tree

type TraversingState = State Configuration

takeValuesByKey :: Text -> TraversingState [ConfigValue]
takeValuesByKey key = do
  config <- get
  put $ Map.delete key config
  return $ fromMaybe [] $ config !? key

takeUniqueValue :: Text -> TraversingState (Maybe ConfigValue)
takeUniqueValue key = unique <$> takeValuesByKey key
 where
  unique :: [a] -> Maybe a
  unique (_ : _ : _) = throw $ DuplicateKey key
  unique list        = listToMaybe list

takeMandatoryValue :: Text -> TraversingState ConfigValue
takeMandatoryValue key = fromMaybe (throw $ UndefinedKey key) <$> takeUniqueValue key

ensureNoValue :: Text -> TraversingState ()
ensureNoValue key = do
  value <- takeUniqueValue key
  case value of
    Nothing -> return ()
    _       -> throw $ UnexpectedKey key

toTextValue :: Text -> ConfigValue -> Text
toTextValue _   (TextValue txt) = txt
toTextValue key _               = throw $ TextValueExpected key

toNestedConfig :: Text -> ConfigValue -> Configuration
toNestedConfig _   (NestedConfig cfg) = cfg
toNestedConfig key _                  = throw $ NestedConfigExpected key

toInteger :: Text -> Text -> Integer
toInteger key value = case decimal $ Text.strip value of
  Left  _              -> throw $ IntegerExpected key value
  Right (value', tail) -> if tail == "" then value' else throw $ IntegerExpected key value

toBool :: Text -> Text -> Bool
toBool key value = case Text.strip value of
  "1"     -> True
  "0"     -> False
  "True"  -> True
  "False" -> False
  _       -> throw $ BoolExpected key value

toRatio :: Text -> Text -> Rational
toRatio key value = case map (toInteger key) $ Text.splitOn "/" value of
  [x]    -> fromIntegral x
  [a, b] -> a % b
  _      -> throw $ RationalExpected key value

toUTC :: Text -> Text -> UTCTime
toUTC key value = case parseTimeM True defaultTimeLocale "%F %R" $ unpack value of
  (Just value) -> value
  Nothing      -> throw $ TimeExpected key value

toIntervalValue :: Text -> Text -> Set Integer
toIntervalValue key =
  mconcat . map (readInterval key . map (toInteger key . Text.strip) . Text.splitOn "-") . Text.splitOn ","
 where
  readInterval :: Text -> [Integer] -> Set Integer
  readInterval _   [x]    = Set.singleton x
  readInterval _   [l, r] = Set.fromDistinctAscList [l .. r]
  readInterval key _      = throw $ InvalidInterval key

ensureEmptyState :: TraversingState ()
ensureEmptyState = do
  cfg <- get
  return $ case Map.lookupMin cfg of
    Nothing       -> ()
    Just (key, _) -> throw $ UnexpectedKey key

-- Utilities

(|>) :: Functor f => (a -> f b) -> (a -> b -> c) -> a -> f c
(|>) f1 f2 x = f2 x <$> f1 x

(||>) :: (Functor f, Functor g) => (a -> f (g b)) -> (a -> b -> c) -> a -> f (g c)
(||>) f1 f2 x = (f2 x <$>) <$> f1 x

skipKey :: (b -> c) -> a -> b -> c
skipKey f _ = f

(==>) :: Bool -> a -> [a]
(==>) False _ = []
(==>) True  x = [x]

-- Configuration readers

buildExtraDeadline :: Configuration -> StandingOption
buildExtraDeadline = evalState $ do
  valueContestIDs    <- takeMandatoryValue |> toTextValue |> toIntervalValue $ "ContestIDs"
  valueContestantIDs <- takeUniqueValue ||> toTextValue ||> toIntervalValue $ "ContestantIDs"
  valueDeadline      <- takeMandatoryValue |> toTextValue |> toUTC $ "Deadline"
  !_                 <- ensureEmptyState
  return $ SetFixedDeadline valueContestIDs valueDeadline valueContestantIDs

buildExtraDeadlines :: TraversingState [StandingOption]
buildExtraDeadlines = do
  deadlines <- takeValuesByKey ||> toNestedConfig $ "SetFixedDeadline"
  return $ fmap buildExtraDeadline $ deadlines

buildStandingOptions :: TraversingState [StandingOption]
buildStandingOptions = do
  reversedContestOrder <-
    takeUniqueValue ||> toTextValue ||> toBool |> skipKey (fromMaybe False) $ "ReversedContestOrder"
  enableDeadlines    <- takeUniqueValue ||> toTextValue ||> toBool |> skipKey (fromMaybe False) $ "EnableDeadlines"
  setDeadlinePenalty <- if enableDeadlines
    then takeMandatoryValue |> toTextValue |> toRatio $ "SetDeadlinePenalty"
    else undefined
  showProblemStatistics <-
    takeUniqueValue ||> toTextValue ||> toBool |> skipKey (fromMaybe False) $ "ShowProblemStatistics"
  enableScores        <- takeUniqueValue ||> toTextValue ||> toBool |> skipKey (fromMaybe False) $ "EnableScores"
  onlyScoreLastSubmit <- takeUniqueValue ||> toTextValue ||> toBool |> skipKey (fromMaybe False) $ "OnlyScoreLastSubmit"
  showLanguages       <- takeUniqueValue ||> toTextValue ||> toBool |> skipKey (fromMaybe False) $ "ShowLanguages"
  extraDeadlines      <- buildExtraDeadlines
  return $ mconcat
    [ reversedContestOrder ==> ReversedContestOrder
    , enableDeadlines ==> EnableDeadlines
    , enableDeadlines ==> SetDeadlinePenalty setDeadlinePenalty
    , showProblemStatistics ==> ShowProblemStatistics
    , enableScores ==> EnableScores
    , onlyScoreLastSubmit ==> OnlyScoreLastSubmit
    , showLanguages ==> ShowLanguages
    , extraDeadlines
    ]

buildStandingConfig :: Configuration -> StandingConfig
buildStandingConfig = evalState $ do
  standName         <- takeMandatoryValue |> toTextValue $ "Name"
  standContests     <- takeMandatoryValue |> toTextValue |> toIntervalValue $ "Contests"
  standInternalName <- takeMandatoryValue |> toTextValue $ "InternalName"
  standOptions      <- buildStandingOptions
  !_                <- ensureEmptyState
  return $ StandingConfig standName standContests standInternalName standOptions

parseStandingConfig :: FilePath -> IO StandingConfig
parseStandingConfig path = do
  contents <- decodeUtf8 <$> B.readFile path
  let cfg = buildConfig contents
  return $ buildStandingConfig cfg

parseStandingConfigDirectory :: FilePath -> IO [StandingConfig]
parseStandingConfigDirectory path = do
  files <- filter (List.isSuffixOf ".cfg") <$> listDirectory path
  sequence $ map parseStandingConfig files

-- Global configuration

buildGlobalConfiguration :: Configuration -> GlobalConfiguration
buildGlobalConfiguration = evalState $ do
  xmlFilePattern <- takeUniqueValue ||> toTextValue |> skipKey (fromMaybe defaultXMLPath) $ "XMLFilePattern"
  standCfgPath   <- takeUniqueValue ||> toTextValue |> skipKey (fromMaybe defaultCfgPath) $ "StandingConfigurationsPath"
  !_             <- ensureEmptyState
  return $ GlobalConfiguration xmlFilePattern standCfgPath
 where
  defaultXMLPath = xmlFilePattern defaultGlobalConfiguration
  defaultCfgPath = standingConfigurationsPath defaultGlobalConfiguration

parseGlobalConfiguration :: FilePath -> IO GlobalConfiguration
parseGlobalConfiguration path = do
  contents <- decodeUtf8 <$> B.readFile path
  let cfg = buildConfig contents
  return $ buildGlobalConfiguration cfg

retrieveGlobalConfiguration' :: [FilePath] -> IO GlobalConfiguration
retrieveGlobalConfiguration' []            = return defaultGlobalConfiguration
retrieveGlobalConfiguration' (file : rest) = catch (parseGlobalConfiguration file) (noFileExceptionHandler rest)
 where
  noFileExceptionHandler :: [FilePath] -> IOException -> IO GlobalConfiguration
  noFileExceptionHandler rest _ = retrieveGlobalConfiguration' rest

retrieveGlobalConfiguration :: IO GlobalConfiguration
retrieveGlobalConfiguration = retrieveGlobalConfiguration' ["/etc/ejstand/ejstand.cfg", "./cfg/ejstand.cfg"]
