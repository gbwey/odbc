{-# LANGUAGE TypeOperators #-}
{-# LANGUAGE ViewPatterns #-}
{-# LANGUAGE UndecidableInstances #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE CPP #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE DeriveDataTypeable #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE TupleSections #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- | SQL Server database API.

module Database.ODBC.SQLServer
  ( -- * Building
    -- $building

    -- * Basic library usage
    -- $usage

    -- * Connect/disconnect
--    Internal.connect
    connect
  , withConnection
  , Internal.close
  , Internal.Connection
  , Internal.AutoCommit(..)
  , Internal.Column(..)
  , Internal.commit
  , Internal.rollback

    -- * Executing queries
  , exec
  , query

  , queryAll'
  , queryAll
  , queryAllList
  , queryAllMap
  , queryAllList'
  , queryAllMap'

  , Internal.ResultSet(..)
  , Internal.ResultSets
  , Internal.RMeta

  , Value(..)
  , SqlValue
  , Query
  , ToSql(..)
  , rawUnescapedText
  , FromValue(..)
  , FromRow(..)
  , Internal.Binary(..)
  , Datetime2(..)
  , Smalldatetime(..)

    -- * Streaming results
    -- $streaming

  , stream
  , Internal.Step(..)

    -- * Exceptions
    -- $exceptions

  , Internal.ODBCException(..)

   -- * Debugging
  , renderQuery

  , buildSqlQueryFromList
  , buildSqlQueryFromListHelper
  , partListParseOnly
  , PartList (..)
  , paramCountList

  , buildSqlQueryFromMap
  , buildSqlQueryFromMapHelper
  , partMapParseOnly
  , PartMap (..)
  , Part (..)
  , paramCountMap

  , renderValue
  , renderParts
  , renderPart

  ) where


import           Control.DeepSeq
import           Control.Exception
import           Control.Monad.IO.Class
import           Control.Monad.IO.Unlift
import           Data.ByteString (ByteString)
import qualified Data.ByteString as S
import qualified Data.ByteString.Lazy as L
import           Data.Char
import           Data.Data
import           Data.Fixed
import           Data.Foldable
import           Data.Int
import           Data.Monoid (Monoid, (<>))
import           Data.Semigroup (Semigroup)
import           Data.Sequence (Seq)
import qualified Data.Sequence as Seq
import           Data.String
import           Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Lazy as LT
import           Data.Time
import           Data.Word
import           Database.ODBC.Conversion
import           Database.ODBC.Internal (SqlValue, Value(..), Connection)
import qualified Database.ODBC.Internal as Internal
import qualified Formatting
import           Formatting ((%))
import           Formatting.Time as Formatting
import           GHC.Generics
import           Text.Printf
import qualified Data.Map.Strict as M
import Data.Map.Strict (Map)
import qualified Data.Set as Set
import Data.Set (Set)
import           qualified Text.Parsec as P
import           qualified Text.Parsec.String as P
import Control.Applicative
import Control.Monad
import qualified UnliftIO as U
import Control.Arrow (first)

#if MIN_VERSION_base(4,9,0)
import           GHC.TypeLits
#endif

-- $building
--
-- You have to compile your projects using the @-threaded@ flag to
-- GHC. In your .cabal file, this would look like: @ghc-options: -threaded@

-- $usage
--
-- An example program using this library:
--
-- @
-- {-\# LANGUAGE OverloadedStrings \#-}
-- import Database.ODBC
-- main :: IO ()
-- main = do
--   conn <-
--     connect
--       "DRIVER={ODBC Driver 13 for SQL Server};SERVER=192.168.99.100;Uid=SA;Pwd=Passw0rd"
--   exec conn "DROP TABLE IF EXISTS example"
--   exec conn "CREATE TABLE example (id int, name ntext, likes_tacos bit)"
--   exec conn "INSERT INTO example VALUES (1, \'Chris\', 0), (2, \'Mary\', 1)"
--   rows <- query conn "SELECT * FROM example" :: IO [[Value]]
--   print rows
--   rows2 <- query conn "SELECT * FROM example" :: IO [(Int,Text,Bool)]
--   print rows2
--   close conn
-- @
--
-- The @rows@ list contains rows of some value that could be
-- anything. The @rows2@ list contains tuples of exactly @Int@,
-- @Text@ and @Bool@. This is achieved via the 'FromRow' class.
--
-- You need the @OverloadedStrings@ extension so that you can write
-- 'Text' values for the queries and executions.
--
-- The output of this program for @rows@:
--
-- @
-- [[IntValue 1, TextValue \"Chris\", BoolValue False],[ IntValue 2, TextValue \"Mary\", BoolValue True]]
-- @
--
-- The output for @rows2@:
--
-- @
-- [(1,\"Chris\",False),(2,\"Mary\",True)]
-- @

-- $exceptions
--
-- Proper connection handling should guarantee that a close happens at
-- the right time. Here is a better way to write it:
--
-- @
-- {-\# LANGUAGE OverloadedStrings \#-}
-- import Control.Exception
-- import Database.ODBC.SQLServer
-- main :: IO ()
-- main =
--   bracket
--     (connect
--        "DRIVER={ODBC Driver 13 for SQL Server};SERVER=192.168.99.100;Uid=SA;Pwd=Passw0rd")
--     close
--     (\\conn -> do
--        rows <- query conn "SELECT N'Hello, World!'"
--        print rows)
-- @
--
-- If an exception occurs inside the lambda, 'bracket' ensures that
-- 'close' is called.

-- $streaming
--
-- Loading all rows of a query result can be expensive and use a lot
-- of memory. Another way to load data is by fetching one row at a
-- time, called streaming.
--
-- Here's an example of finding the longest string from a set of
-- rows. It outputs @"Hello!"@. We only work on 'Text', we ignore
-- for example the @NULL@ row.
--
-- @
-- {-\# LANGUAGE OverloadedStrings, LambdaCase \#-}
-- import qualified Data.Text as T
-- import           Control.Exception
-- import           Database.ODBC.SQLServer
-- main :: IO ()
-- main =
--   bracket
--     (connect
--        \"DRIVER={ODBC Driver 13 for SQL Server};SERVER=192.168.99.101;Uid=SA;Pwd=Passw0rd\")
--     close
--     (\\conn -> do
--        exec conn \"DROP TABLE IF EXISTS example\"
--        exec conn \"CREATE TABLE example (name ntext)\"
--        exec
--          conn
--          \"INSERT INTO example VALUES (\'foo\'),(\'bar\'),(NULL),(\'mu\'),(\'Hello!\')\"
--        longest <-
--          stream
--            conn
--            \"SELECT * FROM example\"
--            (\\longest text ->
--               pure
--                 (Continue
--                    (if T.length text > T.length longest
--                        then text
--                        else longest)))
--            \"\"
--        print longest)
-- @

--------------------------------------------------------------------------------
-- Types

-- | A query builder.  Use 'toSql' to convert Haskell values to this
-- type safely.
--
-- It's an instance of 'IsString', so you can use @OverloadedStrings@
-- to produce plain text values e.g. @"SELECT 123"@.
--
-- It's an instance of 'Monoid', so you can append fragments together
-- with '<>' e.g. @"SELECT * FROM x WHERE id = " <> toSql 123@.
--
-- This is meant as a bare-minimum of safety and convenience.
newtype Query =
  Query (Seq Part)
  deriving (Monoid, Eq, Show, Typeable, Ord, Generic, Data, Semigroup)

instance NFData Query

instance IsString Query where
  fromString = Query . Seq.fromList . pure . fromString

-- | Do not use for writing your queries. Use when writing instances
-- of 'ToSql' if you want to efficiently include a 'Text'
-- value. Subject to SQL injection risk, so be careful.
rawUnescapedText :: Text -> Query
rawUnescapedText = Query . Seq.singleton . TextPart

-- | A part of a query.
data Part
  = TextPart !Text
  | ValuePart !Value
  deriving (Eq, Show, Typeable, Ord, Generic, Data)

instance NFData Part

instance IsString Part where
  fromString = TextPart . T.pack

-- | The 'LocalTime' type has more accuracy than the @datetime@ type and
-- the @datetime2@ types can hold; so you will lose precision when you
-- insert. Use this type to indicate that you are aware of the
-- precision loss and fine with it.
--
-- <https://docs.microsoft.com/en-us/sql/t-sql/data-types/datetime2-transact-sql?view=sql-server-2017>
--
-- If you are using @smalldatetime@ in SQL Server, use instead the
-- 'Smalldatetime' type.
newtype Datetime2 = Datetime2
  { unDatetime2 :: LocalTime
  } deriving (Eq, Ord, Show, Typeable, Generic, Data, FromValue)

-- | Use this type to discard higher precision than seconds in your
-- 'LocalTime' values for a schema using @smalldatetime@.
--
-- <https://docs.microsoft.com/en-us/sql/t-sql/data-types/smalldatetime-transact-sql?view=sql-server-2017>
newtype Smalldatetime = Smalldatetime
  { unSmalldatetime :: LocalTime
  } deriving (Eq, Ord, Show, Typeable, Generic, Data, FromValue)

--------------------------------------------------------------------------------
-- Conversion to SQL

-- | Handy class for converting values to a query safely.
--
-- For example: @query c (\"SELECT * FROM demo WHERE id > \" <> toSql 123)@
--
-- WARNING: Note that if you insert a value like an 'Int' (64-bit)
-- into a column that is @int@ (32-bit), then be sure that your number
-- fits inside an @int@. Try using an 'Int32' instead to be
-- sure.

-- Below next to each instance you can read which Haskell types
-- corresponds to which SQL Server type.
--
class ToSql a where
  toSql :: a -> Query

instance ToSql a => ToSql (Maybe a) where
  toSql = maybe (Query (Seq.fromList [ValuePart NullValue])) toSql

-- | Converts whatever the 'Value' is to SQL.
instance ToSql Value where
  toSql = Query . Seq.fromList . pure . ValuePart

-- | Corresponds to NTEXT (Unicode) of SQL Server. Note that if your
-- character exceeds the range supported by a wide-char (16-bit), that
-- cannot be sent to the server.
instance ToSql Text where
  toSql = toSql . TextValue

-- | Corresponds to NTEXT (Unicode) of SQL Server. Note that if your
-- character exceeds the range supported by a wide-char (16-bit), that
-- cannot be sent to the server.
instance ToSql LT.Text where
  toSql = toSql . TextValue . LT.toStrict

-- | Corresponds to TEXT (non-Unicode) of SQL Server. For proper
-- BINARY, see the 'Binary' type.
instance ToSql ByteString where
  toSql = toSql . ByteStringValue

instance ToSql Internal.Binary where
  toSql = toSql . BinaryValue

-- | Corresponds to TEXT (non-Unicode) of SQL Server. For Unicode, use
-- the 'Text' type.
instance ToSql L.ByteString where
  toSql = toSql . ByteStringValue . L.toStrict

-- | Corresponds to BIT type of SQL Server.
instance ToSql Bool where
  toSql = toSql . BoolValue

-- | Corresponds to FLOAT type of SQL Server.
instance ToSql Double where
  toSql = toSql . DoubleValue

-- | Corresponds to REAL type of SQL Server.
instance ToSql Float where
  toSql = toSql . FloatValue

-- | Corresponds to BIGINT type of SQL Server.
instance ToSql Int where
  toSql = toSql . IntValue

-- | Corresponds to SMALLINT type of SQL Server.
instance ToSql Int16 where
  toSql = toSql . IntValue . fromIntegral

-- | Corresponds to INT type of SQL Server.
instance ToSql Int32 where
  toSql = toSql . IntValue . fromIntegral

-- | Corresponds to TINYINT type of SQL Server.
instance ToSql Word8 where
  toSql = toSql . ByteValue

-- | Corresponds to DATE type of SQL Server.
instance ToSql Day where
  toSql = toSql . DayValue

-- | Corresponds to TIME type of SQL Server.
--
-- 'TimeOfDay' supports more precision than the @time@ type of SQL
-- server, so you will lose precision and not get back what you inserted.
instance ToSql TimeOfDay where
  toSql = toSql . TimeOfDayValue

#if MIN_VERSION_base(4,9,0)
-- | You cannot use this instance. Wrap your value in either
-- 'Datetime2' or 'Smalldatetime'.
instance GHC.TypeLits.TypeError ('GHC.TypeLits.Text "Instance for LocalTime is disabled:" 'GHC.TypeLits.:$$: 'GHC.TypeLits.Text "Wrap your value in either (Datetime2 foo) or (Smalldatetime foo).") =>
         ToSql LocalTime where
  toSql = toSql

-- | You cannot use this instance. Wrap your value in either
-- 'Datetime2' or 'Smalldatetime'.
instance GHC.TypeLits.TypeError ('GHC.TypeLits.Text "Instance for UTCTime is not possible:" 'GHC.TypeLits.:$$: 'GHC.TypeLits.Text "SQL Server does not support time zones. "'GHC.TypeLits.:$$: 'GHC.TypeLits.Text "You can use utcToLocalTime to make a LocalTime, and" 'GHC.TypeLits.:$$: 'GHC.TypeLits.Text "wrap your value in either (Datetime2 foo) or (Smalldatetime foo).") =>
         ToSql UTCTime where
  toSql = toSql
#endif

-- | Corresponds to DATETIME/DATETIME2 type of SQL Server.
--
-- The 'Datetime2' type has more accuracy than the @datetime@ type and
-- the @datetime2@ types can hold; so you will lose precision when you
-- insert.
instance ToSql Datetime2 where
  toSql = toSql . LocalTimeValue . unDatetime2

-- | Corresponds to SMALLDATETIME type of SQL Server. Precision up to
-- minutes. Consider the seconds field always 0.
instance ToSql Smalldatetime where
  toSql = toSql . LocalTimeValue . shrink . unSmalldatetime
    where
      shrink (LocalTime dd (TimeOfDay hh mm _ss)) =
        LocalTime dd (TimeOfDay hh mm 0)

--------------------------------------------------------------------------------
-- Top-level functions

connect ::
     MonadIO m
  => Internal.AutoCommit
  -> Text -- ^ An ODBC connection string.
  -> m Connection
connect = \case
             Internal.Auto -> Internal.connectAuto
             Internal.Manual -> Internal.connectManual


withConnection :: MonadUnliftIO m
            => Internal.AutoCommit
            -> Text  -- ^ An ODBC connection string.
            -> (Connection -> m a) -- ^ Program that uses the ODBC connection.
            -> m a
withConnection = \case
             Internal.Auto -> Internal.withConnectionAuto
             Internal.Manual -> Internal.withConnectionManual

-- | Query and return a list of rows.
--
-- The @row@ type is inferred based on use or type-signature. Examples
-- might be @(Int, Text, Bool)@ for concrete types, or @[Maybe Value]@
-- if you don't know ahead of time how many columns you have and their
-- type. See the top section for example use.
query ::
     (MonadIO m, FromRow row)
  => Connection -- ^ A connection to the database.
  -> Query -- ^ SQL query.
  -> m [row]
query c (Query ps) = do
  rows <- Internal.query c (renderParts (toList ps))
  case mapM fromRow rows of
    Right rows' -> pure rows'
    Left e -> liftIO (throwIO (Internal.DataRetrievalError e))

-- | Query and return a list of rows.
--
-- The @row@ type is inferred based on use or type-signature. Examples
-- might be @(Int, Text, Bool)@ for concrete types, or @[Maybe Value]@
-- if you don't know ahead of time how many columns you have and their
-- type. See the top section for example use.
queryAll :: (MonadIO m, MonadUnliftIO m)
  => Connection -- ^ A connection to the database.
  -> Query -- ^ SQL query.
  -> m Internal.ResultSets
queryAll c (Query ps) = do
  queryAll' c (renderParts (toList ps))

queryAll' :: (MonadIO m, MonadUnliftIO m)
  => Connection -- ^ A connection to the database.
  -> Text -- ^ SQL query.
  -> m Internal.ResultSets
queryAll' c t = do
  lr <- U.try $ Internal.queryAll c t
  case lr of
    Left (e :: Internal.ODBCException) -> liftIO $ throwIO $ Internal.SqlFailedError t e
    Right ret -> pure ret

queryAllList' :: MonadIO m
  => Connection
  -> [PartList]
  -> [Value]
  -> m Internal.ResultSets
queryAllList' c ps vs = do
  case buildSqlQueryFromListHelper vs ps of
    Left e -> liftIO (throwIO (Internal.ParameterMismatch e))
    Right t -> Internal.queryAll c t

queryAllMap' :: (MonadIO m, MonadUnliftIO m)
  => Connection
  -> [PartMap]
  -> Map String Value
  -> m Internal.ResultSets
queryAllMap' c ps vs = do
  case buildSqlQueryFromMapHelper vs ps of
    Left e -> liftIO (throwIO (Internal.ParameterMismatch e))
    Right t -> queryAll' c t

queryAllList :: MonadIO m
  => Connection
  -> Text
  -> [Value]
  -> m Internal.ResultSets
queryAllList c s vs = do
  case partListParseOnly s of
    Left e -> liftIO (throwIO (Internal.ParseSqlError e))
    Right (_, ps) -> queryAllList' c ps vs

queryAllMap :: (MonadIO m, MonadUnliftIO m)
  => Connection
  -> Text
  -> Map String Value
  -> m Internal.ResultSets
queryAllMap c s vs = do
  case partMapParseOnly s of
    Left e -> liftIO (throwIO (Internal.ParseSqlError e))
    Right (_,ps) -> queryAllMap' c ps vs

-- | Render a query to a plain text string. Useful for debugging and
-- testing.
renderQuery :: Query -> Text
renderQuery (Query ps) = (renderParts (toList ps))

-- | Stream results like a fold with the option to stop at any time.
stream ::
     (MonadUnliftIO m, FromRow row)
  => Connection -- ^ A connection to the database.
  -> Query -- ^ SQL query.
  -> (state -> row -> m (Internal.Step state))
  -- ^ A stepping function that gets as input the current @state@ and
  -- a row, returning either a new @state@ or a final @result@.
  -> state
  -- ^ A state that you can use for the computation. Strictly
  -- evaluated each iteration.
  -> m state
  -- ^ Final result, produced by the stepper function.
stream c (Query ps) cont nil =
  Internal.stream
    c
    (renderParts (toList ps))
    (\state row ->
       case fromRow row of
         Left e -> liftIO (throwIO (Internal.DataRetrievalError e))
         Right row' -> cont state row')
    nil

-- | Execute a statement on the database.
exec ::
     MonadIO m
  => Connection -- ^ A connection to the database.
  -> Query -- ^ SQL statement.
  -> m ()
exec c (Query ps) = Internal.exec c (renderParts (toList ps))

--------------------------------------------------------------------------------
-- Query building

-- | Convert a list of parts into a query.
renderParts :: [Part] -> Text
renderParts = T.concat . map renderPart

-- | Render a query part to a query.
renderPart :: Part -> Text
renderPart =
  \case
    TextPart t -> t
    ValuePart v -> renderValue v

-- | Render a value to a query.
renderValue :: Value -> Text
renderValue =
  \case
    NullValue -> "NULL"
    TextValue t -> "'" <> T.concatMap escapeChar t <> "'"
--    TextValue t -> "(N'" <> T.concatMap escapeChar t <> "')"  -- deathly slow on oracle: may need another type? or just use bytestring
    BinaryValue (Internal.Binary bytes) ->
      "0x" <>
      T.concat
        (map
           (Formatting.sformat
              (Formatting.left 2 '0' Formatting.%. Formatting.hex))
           (S.unpack bytes))
    ByteStringValue xs ->
      "('" <> T.concat (map escapeChar8 (S.unpack xs)) <> "')"
    BoolValue True -> "1"
    BoolValue False -> "0"
    ByteValue n -> Formatting.sformat Formatting.int n
    DoubleValue d -> Formatting.sformat Formatting.float d
    FloatValue d -> Formatting.sformat Formatting.float (realToFrac d :: Double)
    IntValue d -> Formatting.sformat Formatting.int d
    DayValue d -> Formatting.sformat ("'" % Formatting.dateDash % "'") d
    TimeOfDayValue (TimeOfDay hh mm ss) ->
      Formatting.sformat
        ("'" % Formatting.left 2 '0' % ":" % Formatting.left 2 '0' % ":" %
         Formatting.string %
         "'")
        hh
        mm
        (renderFractional ss)
    LocalTimeValue (LocalTime d (TimeOfDay hh mm ss)) ->
      Formatting.sformat
        ("'" % Formatting.dateDash % " " % Formatting.left 2 '0' % ":" %
         Formatting.left 2 '0' %
         ":" %
         Formatting.string %
         "'")
        d
        hh
        mm
        (renderFractional ss)

-- | Obviously, this is not fast. But it is correct. A faster version
-- can be written later.
renderFractional :: Pico -> String
renderFractional x = trim (printf "%.7f" (realToFrac x :: Double) :: String)
  where
    trim s =
      reverse (case dropWhile (== '0') (reverse s) of
                 s'@('.':_) -> '0' : s'
                 s' -> s')

-- | A very conservative character escape.
escapeChar8 :: Word8 -> Text
escapeChar8 ch =
  if allowedChar (toEnum (fromIntegral ch))
     then T.singleton (toEnum (fromIntegral ch))
     else "'+CHAR(" <> Formatting.sformat Formatting.int ch <> ")+'"

-- | A very conservative character escape.
escapeChar :: Char -> Text
escapeChar ch =
  if allowedChar ch
     then T.singleton ch
     else "'+NCHAR(" <> Formatting.sformat Formatting.int (fromEnum ch) <> ")+'"

-- | Is the character allowed to be printed unescaped? We only print a
-- small subset of ASCII just for visually debugging later
-- on. Everything else is escaped.
allowedChar :: Char -> Bool
allowedChar c = (isAlphaNum c && isAscii c) || elem c (" ,.-_" :: [Char])

--------------------------------------


data PartMap
    = SqlPartMap !Text
    | ParamNameMap !String
    deriving (Show, Eq)

paramCountMap :: [PartMap] -> Int
paramCountMap  = sum . map (\case
                           ParamNameMap {} -> 1
                           SqlPartMap {} -> 0)

paramCountList :: [PartList] -> Int
paramCountList  = sum . map (\case
                           ParamNameList {} -> 1
                           SqlPartList {} -> 0)

partMapParser :: P.Parser (Int, [PartMap])
partMapParser = first sum . unzip <$> P.many1 (self <|> param <|> part)
  where
    self = P.try ((0, SqlPartMap "$") <$ P.string "$$") P.<?> "escaped dollar $$"
    param =
      (P.char '$' *>
       ((1,) . ParamNameMap <$>
        (P.many1 (P.satisfy isAlphaNum)) P.<?> "variable name (alpha-numeric only)")) P.<?>
      "parameter (e.g. $foo123)"
    part = ((0,) . SqlPartMap . T.pack <$> P.many1 (P.satisfy (/= '$'))) P.<?> "SQL code"

data PartList
    = SqlPartList !Text
    | ParamNameList
    deriving (Show, Eq)

partListParser :: P.Parser (Int, [PartList])
partListParser = first sum . unzip <$> P.many1 (self <|> param <|> part)
  where
    self = P.try ((0,SqlPartList "?") <$ P.string "??") P.<?> "escaped questionmark ??"
    param = (1,ParamNameList) <$ P.char '?'
    part = ((0,) . SqlPartList . T.pack <$> P.many1 (P.satisfy (/= '?'))) P.<?> "SQL code"

partListParseOnly :: Text -> Either String (Int, [PartList])
partListParseOnly (T.unpack -> input) = do
  case P.parse partListParser "<partListParseOnly>" input of
    Left err    -> Left $ "Parse error in SQL: " <> show err <> " sql=" <> input
    Right parts -> pure parts

partMapParseOnly :: Text -> Either String (Int, [PartMap])
partMapParseOnly (T.unpack -> input) = do
  case P.parse partMapParser "<partMapParseOnly>" input of
    Left err    -> Left $ "Parse error in SQL: " <> show err <> " sql=" <> input
    Right parts -> pure parts

buildSqlQueryFromMap :: Text -> Map String Value -> Either String Text
buildSqlQueryFromMap input m =
  partMapParseOnly input >>= buildSqlQueryFromMapHelper m . snd

buildSqlQueryFromMapHelper :: Map String Value -> [PartMap] -> Either String Text
buildSqlQueryFromMapHelper m ps =
  case traverse go ps of
    Left e -> Left e
    Right (unzip -> (a,b)) ->
      let xs :: Set String
          xs = mconcat a
          ks :: Set String
          ks = M.keysSet m
      in if xs /= ks then Left $ "buildSqlFromMap: not all keys were used up map keys=" ++ show ks ++ " used=" ++ show xs
         else pure $ mconcat b
  where
    go :: PartMap -> Either String (Set String, Text)
    go (SqlPartMap str) = pure (mempty,str)
    go (ParamNameMap name) =
      case M.lookup name m of
        Nothing -> Left $ "buildSqlFromMap: key not found [" ++ name ++ "] in map=" ++ show m
        Just v -> pure (Set.singleton name, renderValue v)

buildSqlQueryFromList :: Text -> [Value] -> Either String Text
buildSqlQueryFromList input m = do
  partListParseOnly input >>= buildSqlQueryFromListHelper m . snd

buildSqlQueryFromListHelper  :: [Value] -> [PartList] -> Either String Text
buildSqlQueryFromListHelper vs ps =
  let ret = foldM (\(x,out) -> \case
                        SqlPartList str -> pure (x,out <> str)
                        ParamNameList -> case x of
                                           [] -> Left $ "buildSqlFromList: ran out of args: ps=" ++ show (length ps) ++ " vs=" ++ show (length vs) ++ " ps=" ++ show ps ++ " vs=" ++ show vs
                                           v:zs -> pure (zs, out <> renderValue v)
               ) (vs,mempty) ps
  in case ret of
    Left e -> Left e
    Right ([], t) -> pure t
    Right (o, _) -> Left $ "buildSqlFromList: too many args found: ps=" ++ show (length ps) ++ " vs=" ++ show (length vs) ++ " ps=" ++ show ps ++ " vs=" ++ show vs ++ " leftovers=" ++ show o
