{-# LANGUAGE RecordWildCards #-}

module Config
  ( Config(..)
  , PasswordSource(..)
  , findConfig
  , getCredentials
  ) where

import           Control.Applicative
import           Control.Monad.Trans.Except
import           Data.HashMap.Strict (HashMap)
import qualified Data.HashMap.Strict as HM
import           Data.Ini
import           Data.Text (Text)
import qualified Data.Text as T
import           Data.Monoid ((<>))
import           System.Process (readProcess)
import           Text.Read (readMaybe)

import           Prelude

import           IOUtil
import           FilePaths

-- These helper functions make our Ini parsing a LOT nicer
type IniParser s a = ExceptT String ((->) (Text, s)) a
type Section = HashMap Text Text

-- Run the parser over an Ini file
runParse :: IniParser Ini a -> Ini -> Either String a
runParse mote ini = runExceptT mote ("", ini)

-- Run parsing within a named section
section :: Text -> IniParser Section a -> IniParser Ini a
section name thunk = ExceptT $ \(_, Ini ini) ->
  case HM.lookup name ini of
    Nothing  -> Left ("No section named" ++ show name)
    Just sec -> runExceptT thunk (name, sec)

-- Retrieve a field, returning Nothing if it doesn't exist
fieldM :: Text -> IniParser Section (Maybe Text)
fieldM name = ExceptT $ \(_,m) ->
  return (HM.lookup name m)

-- Retrieve a field, failing to parse if it doesn't exist
field :: Text -> IniParser Section Text
field name = ExceptT $ \(sec,m) ->
  case HM.lookup name m of
    Nothing -> Left ("Missing field " ++ show name ++
                     " in section " ++ show sec)
    Just x  -> return x

-- Retrieve a field and try to 'Read' it to a value, failing
-- to parse if it doesn't exist or if the 'Read' operation
-- fails.
fieldR :: Read a => Text -> IniParser Section a
fieldR name = do
  str <- field name
  case readMaybe (T.unpack str) of
    Just x  -> return x
    Nothing -> fail ("Unable to read field " ++ show name)

-- Retrieve a field and try to 'Read' it to a value,
-- returning Nothing if it doesn't exist or if the 'Read'
-- operation fails
fieldMR :: Read a => Text -> IniParser Section (Maybe a)
fieldMR name = do
  mb <- fieldM name
  return $ case mb of
    Nothing  -> Nothing
    Just str -> readMaybe (T.unpack str)

-- Retrieve a field and treat it as a boolean, subsituting
-- a default value if it doesn't exist
fieldFlag :: Text -> Bool -> IniParser Section Bool
fieldFlag name def = do
  mb <- fieldM name
  case mb of
    Nothing  -> return def
    Just str -> case toBool str of
      Nothing -> fail ("Unknown boolean value " ++ show str ++
                       " for field " ++ show name)
      Just b  -> return b
  where toBool s = case T.toLower s of
          "true"  -> Just True
          "yes"   -> Just True
          "t"     -> Just True
          "y"     -> Just True
          "false" -> Just False
          "no"    -> Just False
          "f"     -> Just False
          "n"     -> Just False
          _       -> Nothing

data PasswordSource =
    PasswordString Text
    | PasswordCommand Text
    deriving (Eq, Read, Show)

data Config = Config
  { configUser           :: Maybe Text
  , configHost           :: Text
  , configTeam           :: Maybe Text
  , configPort           :: Int
  , configPass           :: Maybe PasswordSource
  , configTimeFormat     :: Maybe Text
  , configDateFormat     :: Maybe Text
  , configTheme          :: Maybe Text
  , configSmartBacktick  :: Bool
  , configURLOpenCommand :: Maybe Text
  , configActivityBell   :: Bool
  , configShowMessagePreview :: Bool
  } deriving (Eq, Show)

fromIni :: Ini -> Either String Config
fromIni = runParse $ do
  section "mattermost" $ do
    configUser           <- fieldM  "user"
    configHost           <- field   "host"
    configTeam           <- fieldM  "team"
    configPort           <- fieldR  "port"
    configTimeFormat     <- fieldM  "timeFormat"
    configDateFormat     <- fieldM  "dateFormat"
    configTheme          <- fieldM  "theme"
    configURLOpenCommand <- fieldM  "urlOpenCommand"
    pass                 <- fieldM  "pass"
    passCmd              <- fieldM  "passcmd"
    configSmartBacktick      <- fieldFlag "smartbacktick" True
    configShowMessagePreview <- fieldFlag "showMessagePreview" False
    configActivityBell       <- fieldFlag "activityBell" False
    let configPass = case passCmd of
          Nothing -> case pass of
            Nothing -> Nothing
            Just p  -> Just (PasswordString p)
          Just c -> Just (PasswordCommand c)
    return Config { .. }

findConfig :: Maybe FilePath -> IO (Either String Config)
findConfig Nothing = do
    let err = "Configuration file " <> show configFileName <> " not found"
    maybe (return $ Left err) getConfig =<< locateConfig configFileName
findConfig (Just path) = getConfig path

getConfig :: FilePath -> IO (Either String Config)
getConfig fp = runExceptT $ do
  t <- (convertIOException $ readIniFile fp) `catchE`
       (\e -> throwE $ "Could not read " <> show fp <> ": " <> e)
  case t >>= fromIni of
    Left err -> do
      throwE $ "Unable to parse " ++ fp ++ ":" ++ err
    Right conf -> do
      actualPass <- case configPass conf of
        Just (PasswordCommand cmdString) -> do
          let (cmd:rest) = T.unpack <$> T.words cmdString
          output <- convertIOException (readProcess cmd rest "") `catchE`
                    (\e -> throwE $ "Could not execute password command: " <> e)
          return $ Just $ T.pack (takeWhile (/= '\n') output)
        Just (PasswordString pass) -> return $ Just pass
        _ -> return Nothing
      return conf { configPass = PasswordString <$> actualPass }

getCredentials :: Config -> Maybe (Text, Text)
getCredentials config = case (,) <$> configUser config <*> configPass config of
  Nothing                    -> Nothing
  Just (u, PasswordString p) -> Just (u, p)
  _ -> error $ "BUG: unexpected password state: " <> show (configPass config)
