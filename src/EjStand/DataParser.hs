{-# LANGUAGE OverloadedStrings #-}
module EjStand.DataParser
  ( ParsingException(..)
  , parseEjudgeXML
  , parseEjudgeXMLs
  )
where

import           Prelude                 hiding ( readFile )

import           Data.Text                      ( Text
                                                , unpack
                                                )
import qualified Data.Text                     as Text
                                                ( null
                                                , concat
                                                )
import           Data.Text.Read                 ( signed
                                                , decimal
                                                )
import           Data.Maybe                     ( mapMaybe )
import           Data.Map.Strict                ( Map )
import qualified Data.Map.Strict               as Map
                                                ( lookup )
import qualified Data.Set                      as Set
                                                ( fromDistinctAscList
                                                , singleton
                                                )
import           Data.Time                      ( UTCTime
                                                , parseTimeM
                                                , defaultTimeLocale
                                                , addUTCTime
                                                )

import           Control.Exception              ( Exception
                                                , throw
                                                )
import           Text.XML

import           EjStand.BaseModels
import           EjStand.StandingsModels        ( StandingsSource(..) )

-- Exceptions

nameToString :: Name -> String
nameToString = unpack . nameLocalName

data ParsingException = UndefinedAttribute Name
                      | UndefinedChild Name
                      | AmbiguousChild Name
                      | InvalidInteger Text
                      | RunsInNotStartedContest

instance Exception ParsingException

instance Show ParsingException where
  show (UndefinedAttribute value) = "Undefined attribute \"" ++ nameToString value ++ "\""
  show (UndefinedChild     value) = "Child element \"" ++ nameToString value ++ "\" not found"
  show (AmbiguousChild     value) = "Ambiguous child element \"" ++ nameToString value ++ "\" instances"
  show (InvalidInteger     value) = "Can't convert string \"" ++ unpack value ++ "\" to integer type"
  show RunsInNotStartedContest    = "There are runs in a contest which has not started yet"

-- Attribute and Node extraction functions

getMaybeAttributeValue :: Name -> Element -> Maybe Text
getMaybeAttributeValue attr = Map.lookup attr . elementAttributes

getAttributeValue :: Name -> Element -> Text
getAttributeValue attr elem = case getMaybeAttributeValue attr elem of
  Nothing  -> throw $ UndefinedAttribute attr
  Just val -> val

toElement :: Node -> Maybe Element
toElement (NodeElement e) = Just e
toElement _               = Nothing

getChilds :: Name -> Element -> [Element]
getChilds name = filter ((== name) . elementName) . mapMaybe toElement . elementNodes

getChild :: Name -> Element -> Element
getChild name elem = case getChilds name elem of
  [value] -> value
  []      -> throw $ UndefinedChild name
  _       -> throw $ AmbiguousChild name

readIntegral :: Text -> Integer
readIntegral str = case (signed decimal) str of
  Left  _             -> throw $ InvalidInteger str
  Right (value, tail) -> if Text.null tail then value else throw $ InvalidInteger str

getTextContents :: Element -> Text
getTextContents = Text.concat . map getTextContents' . elementNodes
 where
  getTextContents' :: Node -> Text
  getTextContents' (NodeContent txt) = txt
  getTextContents' _                 = ""

toUTC :: Monad a => Text -> a UTCTime
toUTC = parseTimeM True defaultTimeLocale "%Y/%m/%d %T" . unpack

-- Parsing Models

readContest :: Element -> Contest
readContest root = Contest contestID contestName contestStartTime
 where
  contestID        = readIntegral $ getAttributeValue "contest_id" root
  contestName      = getTextContents . getChild "name" $ root
  contestStartTime = getMaybeAttributeValue "start_time" root >>= toUTC

readContestant :: Element -> Contestant
readContestant elem = Contestant contestantID contestantName
 where
  contestantID   = readIntegral $ getAttributeValue "id" elem
  contestantName = getAttributeValue "name" elem

readContestants :: Element -> [Contestant]
readContestants = map readContestant . getChilds "user" . getChild "users"

readLanguage :: Element -> Language
readLanguage elem = Language languageID languageShortName languageLongName
 where
  languageID        = readIntegral $ getAttributeValue "id" elem
  languageShortName = getAttributeValue "short_name" elem
  languageLongName  = getAttributeValue "long_name" elem

readLanguages :: Element -> [Language]
readLanguages = map readLanguage . getChilds "language" . getChild "languages"

readProblem :: Contest -> Element -> Problem
readProblem contest elem = Problem problemID problemContest problemShortName problemLongName
 where
  problemID        = readIntegral $ getAttributeValue "id" elem
  problemContest   = contestID contest
  problemShortName = getAttributeValue "short_name" elem
  problemLongName  = getAttributeValue "long_name" elem

readProblems :: Contest -> Element -> [Problem]
readProblems contest = map (readProblem contest) . getChilds "problem" . getChild "problems"

makeContestTime :: Contest -> (Integer, Integer) -> UTCTime
makeContestTime contest (sec, nsec) = makeContestTime' (contestStartTime contest) (fromIntegral sec, fromIntegral nsec)
 where
  makeContestTime' :: Maybe UTCTime -> (Double, Double) -> UTCTime
  makeContestTime' Nothing     _           = throw RunsInNotStartedContest
  makeContestTime' (Just time) (sec, nsec) = addUTCTime (realToFrac (nsec * 1e-9 + sec)) time

readRun :: Contest -> Element -> Run
readRun contest elem = Run runID runContest runContestant runProblem runTime runStatus runLanguage runScore runTest
 where
  runID         = readIntegral $ getAttributeValue "run_id" elem
  runContest    = contestID contest
  runContestant = readIntegral $ getAttributeValue "user_id" elem
  runProblem    = readIntegral <$> getMaybeAttributeValue "prob_id" elem
  runTime =
    makeContestTime contest (readIntegral $ getAttributeValue "time" elem, readIntegral $ getAttributeValue "nsec" elem)
  runStatus   = read . unpack $ getAttributeValue "status" elem
  runLanguage = readIntegral <$> getMaybeAttributeValue "lang_id" elem
  runScore    = readIntegral <$> getMaybeAttributeValue "score" elem
  runTest     = readIntegral <$> getMaybeAttributeValue "test" elem

readRuns :: Contest -> Element -> [Run]
readRuns contest = map (readRun contest) . getChilds "run" . getChild "runs"

-- Parser Frontend

parseEjudgeXML :: FilePath -> IO StandingsSource
parseEjudgeXML file = do
  root <- documentRoot <$> readFile def file
  let contest    = readContest root
      usersSet   = Set.fromDistinctAscList $ readContestants root
      langsSet   = Set.fromDistinctAscList $ readLanguages root
      probsSet   = Set.fromDistinctAscList $ readProblems contest root
      runsSet    = Set.fromDistinctAscList $ readRuns contest root
      contestSet = Set.singleton $ contest
  return $ StandingsSource contestSet usersSet langsSet probsSet runsSet

parseEjudgeXMLs :: [FilePath] -> IO StandingsSource
parseEjudgeXMLs filelist = do
  sources <- sequence $ map parseEjudgeXML filelist
  return $ mconcat sources
