-- |
-- Module      :  Main
-- Copyright   :  (c) 2013-2016 Galois, Inc.
-- License     :  BSD3
-- Maintainer  :  cryptol@galois.com
-- Stability   :  provisional
-- Portability :  portable

import Cryptol.Parser.Lexer
import Cryptol.Parser.PP

main :: IO ()
main = interact (unlines . map (show . pp) . fst . primLexer)
