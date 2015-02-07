{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}


module XmlLikeFormat where

-------------------------------------------------------------------------------
-- LOCAL
-------------------------------------------------------------------------------
import MonadTypesInstances
import SmartCopy

-------------------------------------------------------------------------------
-- SITE-PACKAGES
-------------------------------------------------------------------------------
import qualified Data.List as L
import qualified Data.Text as T
import Data.String.Utils

-------------------------------------------------------------------------------
-- STDLIB
-------------------------------------------------------------------------------
import Control.Monad.Loops
import Control.Monad.Reader
import Control.Monad.State
import Control.Monad.Writer

serializeSmart a = runSerialization (writeSmart xmlLikeSerializationFormat a)
    where runSerialization m = execWriter (runStateT m [])

parseSmart :: SmartCopy a => String -> Fail a
parseSmart = runParser (readSmart xmlLikeParseFormat)
    where runParser action value = evalState (evalStateT (runFailT action) value) []

xmlLikeSerializationFormat :: SerializationFormat (StateT [String] (Writer String))
xmlLikeSerializationFormat
    = SerializationFormat
    { withCons =
          \cons m ->
          do let conName = T.unpack $ cname cons
             tell $ openTag conName
             let fields
                    = case cfields cons of
                        Left 0 ->
                            []
                        Left i ->
                            map show [0..i-1]
                        Right ls ->
                            map T.unpack ls
             put fields
             m
             tell $ closeTag conName
    , withField =
          \m ->
              do fields <- get
                 case fields of
                   field:rest ->
                       do tell $ openTag field
                          m
                          put rest
                          tell $ closeTag field
                   [field] ->
                       do tell $ openTag field
                          m
                          tell $ closeTag field
                   [] -> m
    , withRepetition =
          \list ->
              forM_ (zip list (repeat "value")) $
              \el ->
                  do tell $ openTag $ snd el
                     writeSmart xmlLikeSerializationFormat $ fst el
                     tell $ closeTag $ snd el
    , writePrimitive =
          \prim ->
            case prim of
              PrimInt i -> tell $ show i
              PrimBool b -> tell $ show b
              PrimString s -> tell s
              PrimDouble d -> tell $ show d
    }
                

xmlLikeParseFormat :: ParseFormat (FailT (StateT String (State [String])))
xmlLikeParseFormat
    = ParseFormat
    { readCons =
          \cons ->
              do str <- get
                 let conNames = map (T.unpack . cname . fst) cons
                     conFields = map (cfields . fst) cons
                     parsers = map snd cons
                 case length cons of
                   0 -> fail "Parsing failure. No constructor to look up."
                   _ ->
                       do con <- readOpen
                          case lookup con (zip conNames parsers) of
                            Just parser ->
                                 do let Just cfields = lookup con (zip conNames conFields)
                                        fields
                                            = case cfields of
                                                Left i -> map show [0..i-1]
                                                Right lbs -> map T.unpack lbs
                                    lift $ lift $ put fields
                                    rest <- get
                                    res <- parser
                                    _ <- readCloseWith con
                                    return res
                            f -> fail $
                                 "Parsing failure. Didn't find \
                                 \constructor for tag " ++ show con ++
                                 ". Only found " ++ show conNames ++ "."
    , readField =
          \ma ->
              do str <- get
                 fields <- lift $ lift get
                 case fields of
                   [] -> ma
                   (x:xs) ->
                       do _ <- readOpenWith x
                          res <- ma
                          _ <- readCloseWith x
                          lift $ lift $ put xs
                          return res
    , readRepetition =
          do whileJust enterElemMaybe $
                 \_ ->
                     do res <- readSmart xmlLikeParseFormat
                        _ <- readCloseWith "value"
                        return res
    , readPrim =
          do str' <- get
             let str = filter (/=' ') str'
             case reads str of
               [(prim, rest)] ->
                   do lift $ put rest
                      return $ PrimDouble prim
               [] ->
                   case take 4 str of
                     "True" ->
                         do lift $ put $ drop 4 str
                            return $ PrimBool True
                     _ ->
                        case take 5 str of
                          "False" ->
                               do lift $ put $ drop 5 str
                                  return $ PrimBool False
                          _ ->
                            do lift $ put $ snd $ delimit str
                               return $ PrimString $ fst $ delimit str
                            where delimit str = L.span (/='<') str
    }

openTag s = "<" ++ s ++ ">"
closeTag  s = "</" ++ s ++ ">"
unwrap s 
    | startswith "</" s && endswith ">" s = init $ drop 2 s
    | startswith "<" s && endswith ">" s = init $ drop 1 s
    | otherwise = s

dropLast n xs = take (length xs - n) xs

readOpen :: FailT (StateT String (State [String])) String
readOpen =
    do str <- get
       case isTagOpen str of
         True ->
             do let ('<':tag, '>':after)  = L.span (/='>') str
                put after
                return tag
         False ->
             fail $ "Didn't find an opening tag at " ++ str ++ "."
    where isTagOpen s = (startswith "<" s) && (not $ startswith "</" s)
                 
readClose :: FailT (StateT String (State [String])) String
readClose =
    do str <- get
       case startswith "</" str of
         True ->
             do let (tag, '>':after) = L.span (/='>') str
                put after
                return tag
         False ->
             fail $ "Didn't find a closing tag at " ++ str ++ "."

readOpenWith :: String -> FailT (StateT String (State [String])) String
readOpenWith s =
    do str <- get
       case startswith (openTag s) str of
         True ->
            do let (tag, '>':after) = L.span (/='>') str
               put after
               return ""
         False ->
            fail $ "Didn't find an opening tag for " ++ s ++
                   " at " ++ str ++ "."

readCloseWith :: String -> FailT (StateT String (State [String])) String
readCloseWith s =
    do str <- get
       case startswith (closeTag s) str of
         True ->
            do let (tag, '>':after) = L.span (/='>') str
               put after
               return ""
         False ->
            fail $ "Didn't find a closing tag for " ++ s ++
                   " at " ++ str ++ "."

enterElemMaybe =
    do str <- get
       case startswith (openTag "value") str of
         True ->
             liftM Just (readOpenWith "value")
         False ->
             return Nothing