module Main where

import Test.Tasty (TestTree, defaultMain, testGroup)
import Test.Tasty.HUnit (assertEqual, assertFailure, testCase)
import Data.HashMap.Strict (HashMap)
import qualified Data.HashMap.Strict as HashMap

import Expresso

main = defaultMain unitTests

unitTests = testGroup
  "End-to-end functional tests"
  [ letTests
  , lambdaTests
  , recordTests
  , variantTests
  , listTests
  , relationalTests
  , inferenceTests
  , constraintTests
  , rankNTests
  , lazyTests
  ]

letTests = testGroup
  "Let expressions"
  [ hasValue "let x = 1 in x" (1::Integer)
  , hasValue "let x = 1 in let y = 2 in x + y" (3::Integer)
  , hasValue "let x = 1; y = 2 in x + y" (3::Integer)
  , hasValue "let {..} = {inc = x -> x + 1} in inc 1" (2::Integer)
  , hasValue "let m = {inc = x -> x + 1} in m.inc 1" (2::Integer)

  , hasValue "let m = {id = x -> x} in {foo = [m.id 1], bar = m.id [1]}"
        ["foo" --> ([1]::[Integer]), "bar" --> ([1]::[Integer])]

  -- Record argument field-pun generalisation
  , hasValue "let {id} = {id = x -> x} in {foo = [id 1], bar = id [1]}"
        ["foo" --> ([1]::[Integer]), "bar" --> ([1]::[Integer])]
  , hasValue "let {..} = {id = x -> x} in {foo = [id 1], bar = id [1]}"
        ["foo" --> ([1]::[Integer]), "bar" --> ([1]::[Integer])]

    -- Num constraint violation
  , illTyped "let square = x -> x * x in {foo = square 1, bar = square [1]}"
  ]

lambdaTests = testGroup
  "Lambda expressions"
  [ hasValue "(x -> y -> x + y) 1 2" (3::Integer)
  , hasValue "(x y -> x + y) 1 2" (3::Integer)
  , illTyped "x -> x x"
  , illTyped "let absorb = fix (r x -> r) in absorb"
  , illTyped "let create = fix (r x -> r x x) in create"
  ]

recordTests = testGroup
  "Record expressions"
  [ hasValue "({x, y} -> {x, y}) {x=1, y=2}" $ toMap ["x"-->(1::Integer), "y"-->2]
  , hasValue "{x = 1, y = 2}" $ toMap ["x"-->(1::Integer), "y"-->2]
  , hasValue "(r -> { x = 1, y = 2 | r}) { z = 3 }" $ toMap ["x"-->(1::Integer), "y"-->2, "z"-->3]
  , hasValue "{ x = { y = { z = 42 }}}.x.y.z" (42::Integer)

  -- Row tail unification soundness
  , illTyped "r -> if True then { x = 1 | r } else { y = 2 | r }"

  , illTyped "{ x = 2, x = 1 }.x" -- fails to typecheck
  , illTyped "{ x = 2 | { x = 1 }}.x" -- fails to typecheck
  , hasValue "{ x := 2, x = 1 }.x" (2::Integer)
  , hasValue "{ x := 2 | { x = 1 }}.x" (2::Integer)
  , hasValue "{| x = 1 |} {}" $ toMap ["x"-->(1::Integer)]
  , hasValue "({| x = 1, y = 2 |} >> {| z = 3 |}) {}" $ toMap ["x"-->(1::Integer), "y"-->2, "z"-->3]
  , hasValue "({| x = 1, y = 2 |} >> {| x := 42 |}) {}" $ toMap ["x"-->(42::Integer), "y"-->2]
  , illTyped "({| x = 1, y = 2 |} << {| x := 42 |}) {}" -- fails to typecheck
  , hasValue "({| x := 42, y = 2 |} << {| x = 1 |}) {}" ["x"-->(42::Integer), "y"-->2]
  ]

variantTests = testGroup
  "Variant expressions"
  [ hasValue "case Foo 1 of { Foo x -> x + 1, Bar {x, y} -> x + y }"   (2::Integer)
  , hasValue "case Bar {x=1, y=2} of { Foo x -> x + 1, Bar {x, y} -> x + y }"   (3::Integer)
  , illTyped "case Baz{} of { Foo x -> x + 1, Bar {x, y} -> x + y }" -- fails to typecheck
  , hasValue "case Baz{} of { Foo x -> x + 1, Bar {x, y} -> x + y | otherwise -> 42 }"  (42::Integer)
  , illTyped "let f = s -> case s of { Foo x -> x + 1, Bar {x, y} -> x + y }; g = s -> f (<|Foo|> s) in g (Foo 1)" -- fails to typecheck
  , hasValue "let f = s -> case s of { Foo x -> x + 1, Bar {x, y} -> x + y }; g = s -> f (<|Foo|> s) in g (Bar{x=1, y=2})" (3::Integer)
  , hasValue "let f = s -> case s of { Foo x -> x + 1, Bar {x, y} -> x + y | otherwise -> 42 }; g = s -> f (<|Foo,Bar|> s) in g (Baz{})"  (42::Integer)
  , hasValue "case Foo 1 of { override Foo x -> x + 2 | s -> case s of { Foo x -> x + 1 }}" (3::Integer)
  , hasValue "case Foo 1 of { override Foo x -> x + 2, Foo x -> x + 1 }" (3::Integer)

  -- Fail in empty row case
  , illTyped "x -> case x of { A{} -> 1, B{} -> 2, A{} -> 3 }"
  -- Fail in row var case
  , illTyped "x -> <|A, B, A|> x"
  -- Failed row rewrite due to row constraints
  , illTyped ("let f = x -> case (<|A|> x) of { B{} -> 1, otherwise -> 2 }; " ++
              "let g = x -> case (<|B|> x) of { A{} -> 1, otherwise -> 2 } in " ++
              "x -> f x + f x")
  ]

listTests = testGroup
  "List expressions"
  [ hasValue "[1,2,3]" [1::Integer,2,3]
  , illTyped "[1,True]"
  ]

relationalTests = testGroup
  "Relational expressions"
  [ hasValue "(1 == 2)" False
  , hasValue "1/=2" True
  , illTyped "1 == 2 == 3"
  , hasValue "{x = 1, y = True} == {y = True, x = 1}" True -- field order should not matter
  , illTyped "{x = 1, y = True} > {y = True, x = 1}" -- cannot compare records for ordering
  , hasValue "Just 1 == Just 1" True -- variants can be compared for equality
  , illTyped "Foo 1 > Bar{}" -- cannot compare variants for ordering
  , hasValue "[1,2,3] == [1,2,3]" True -- lists can be compared for equality
  , hasValue "[1,2,3] >= [1,2,2]" True -- lists can be compared for ordering
  , hasValue "True&&True"   True
  , hasValue "True||False"  True
  ]

inferenceTests = testGroup
  "Type inference tests"
  [ hasType "n d -> if d == 0 then DivBy0 {} else Ok (n / d)"
            "forall r. (r\\DivBy0\\Ok) => Int -> Int -> <DivBy0 : {}, Ok : Int | r>"
  ]

constraintTests = testGroup
  "Constraint violations"
  [ illTyped "show { x = \"test\", y = Just (x -> x) }"
  , illTyped "{ x = 2 } > { x = 1}"
  , illTyped "let f = x y -> x + y in f True False"
  ]

rankNTests = testGroup
  "Rank-N polymorphism"
  [ hasValue "let f = (g : forall a. a -> a) -> {l = g True, r = g 1} in f (x -> x) == {l = True, r = 1}" True
  , hasValue "let f = g -> {l = g True, r = g 1} : (forall a. a -> a) -> {l : Bool, r : Int } in f (x -> x) == {l = True, r = 1}" True , hasValue "let f = (m : forall a. { reverse : [a] -> [a] |_}) -> {l = m.reverse [True, False], r = m.reverse \"abc\" } in f (import \"Prelude.x\") == {l = [False, True], r = \"cba\"}" True
  ]

lazyTests = testGroup
  "Lazy evaluation tests using error primitive"
  [ -- hasValue "maybe (error \"bang!\") (x -> x == 42) (Just 42)" True
    hasValue "{ x = error \"boom!\", y = 42 }.y" (42::Integer)
  , hasValue "case Bar (error \"fizzle!\") of { Foo{} -> 0 | otherwise -> 42 }" (42::Integer)
  ]

hasValue :: (Eq a, Show a, HasValue a) => String -> a -> TestTree
hasValue str expected = testCase str $ do
    result <- evalString str
    case result of
        Left err     -> assertFailure err
        Right actual -> assertEqual "" expected actual

hasType :: String -> String -> TestTree
hasType str expected = testCase str $ do
    result <- typeOfString str
    case result of
        Left err     -> assertFailure err
        Right actual -> assertEqual "" expected (showType actual)

illTyped :: String -> TestTree
illTyped str = testCase str $ do
    sch'e <- typeOfString str
    case sch'e of
        Left _    -> assertTrue
        Right sch -> assertFailure $ "Should not type-check, but got: " ++ showType sch

assertTrue = return ()

(-->) :: HasValue a => Name -> a -> (Name, a)
(-->) l v = (l, v)

toMap :: (Eq a, Show a, HasValue a) => [(Name, a)] -> HashMap Name a
toMap = HashMap.fromList
