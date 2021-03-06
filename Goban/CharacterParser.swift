//
//  FuntionalParser.swift
//  GobanSampleProject
//
//  Created by John on 5/3/16.
//  Copyright © 2016 Boris Emorine. All rights reserved.
//

import Foundation

// 
// MARK: - CharacterParser

//
// Parser is a functional parser combinator which consumes an ArraySlice of Token types
// returns a sequence of (perhaps empty) Result type
//
// https://en.wikipedia.org/wiki/Parser_combinator
//

struct CharacterParser<Result> {
    let parse: (ArraySlice<Character>) -> AnySequence<(Result, ArraySlice<Character>)>
}

//
// MARK: - simple parsers
//

// consumes no Tokens and returns contained T
func pure<T>(_ value: T) -> CharacterParser<T> {
    return CharacterParser { anySequenceOfOne((value, $0)) }
}

// parse tokens equal to token
func parseSatisfying(_ condition: @escaping (Character) -> Bool) -> CharacterParser<Character> {
    return CharacterParser { x in
        guard let (head, tail) = x.decompose, condition(head) else {
            return AnySequence([])
        }
        
        return anySequenceOfOne((head, tail))
    }
}

// parse only the given character
func parseCharacter(_ c: Character) -> CharacterParser<Character> {
    return parseSatisfying { $0 == c }
}

// parse any character in set
func parseCharacterFromSet(_ set: CharacterSet) -> CharacterParser<Character> {
    return parseSatisfying { (ch: Character) in
        let uniChar = (String(ch) as NSString).character(at: 0)
        return set.contains(UnicodeScalar(uniChar)!)
    }
}

// take as many characters from the set as possible, don't provide alternatives
func parseGreedyCharactersFromSet(_ set: CharacterSet) -> CharacterParser<[Character]> {
    func uniChar(_ ch: Character) -> UniChar {
        return String(ch).utf16.first!
    }
    
    return CharacterParser { input in
        let escapeChar = Character("\\")
        var escapeNext = false
        var lastCharInSet: Int?

        for (i,ch) in input.enumerated() {
            if !(set.contains(UnicodeScalar(uniChar(ch))!) || escapeNext) {
                break
            }
            lastCharInSet = i
            escapeNext = (ch == escapeChar) && !escapeNext
        }
        
        guard let _ = lastCharInSet else {
            return emptySequence()
        }
        
        let chars = Array(input.prefix(lastCharInSet! + 1))
        return anySequenceOfOne((chars, input.dropFirst(chars.count)))
    }
}

// eat up whitespace from input and return none of them
func eatWS() -> CharacterParser<[Character]> {
    return (parseGreedyCharactersFromSet(CharacterSet.whitespacesAndNewlines) <|> pure([]))
}

//
// MARK: - combinator operators
//


precedencegroup Choice {
    associativity: right
}

precedencegroup Combinator {
    associativity: left
    higherThan: Choice
}

precedencegroup Apply {
    associativity: left
    higherThan: Combinator
    lowerThan: FunctionArrowPrecedence
}

// choice operator
infix operator <|>: Choice
//{ associativity right precedence 130 }
func <|> <Result>(l: CharacterParser<Result>, r: CharacterParser<Result>) -> CharacterParser<Result> {
    return CharacterParser { l.parse($0) + r.parse($0) }
}

// sequence operator
func sequence<A, B>(_ l: CharacterParser<A>, _ r: CharacterParser<B>) -> CharacterParser<(A,B) > {
    return CharacterParser { input in
        let leftResults = l.parse(input)
        return leftResults.flatMap { (a, leftRest) -> [((A,B), ArraySlice<Character>)]  in
            let rightResult = r.parse(leftRest)
            return rightResult.map { b, rightRest in
                ((a,b), rightRest)
            }
        }
    }
}

// combinator operator
infix operator <*>: Combinator
//{ associativity left precedence 150 }
func <*><A, B>(l: CharacterParser<(A) -> B>, r: CharacterParser<A>) -> CharacterParser<B> {
    typealias Result = (B, ArraySlice<Character>)
    typealias Results = [Result]

    return CharacterParser { input in
        let leftResult = l.parse(input)
        return leftResult.flatMap { (f, leftRest) -> Results in
            let rightResult = r.parse(leftRest)
            return rightResult.map { (right, rightRest) -> Result in
                (f(right), rightRest)
            }
        }
    }
}

// combinator, but throw away the result on right
infix operator <*: Combinator
//{ associativity left precedence 150 }
func <* <A,B>(p: CharacterParser<A>, q: CharacterParser<B>) -> CharacterParser<A> {
    return { x in { _ in x } } </> p <*> q
}

// combinator, but throw away the result on left
infix operator *>: Combinator
//{ associativity left precedence 150 }
func *> <A,B>(p: CharacterParser<A>, q: CharacterParser<B>) -> CharacterParser<B> {
    return { _ in { y in y } } </> p <*> q
}

// apply combinator operator
infix operator </>: Apply
//{ associativity left precedence 170 }
func </><A,B>(f: @escaping (A) -> B, r: CharacterParser<A>) -> CharacterParser<B> {
    return pure(f) <*> r
}

//
// MARK: - convenience combinators
//

// f() returns a parser. f() not evaluate evaluated parse time
func lazy<A>(_ f: @escaping () -> CharacterParser<A>) -> CharacterParser<A> {
    return CharacterParser { f().parse($0) }
}

// return [A]{0,1}
func optional<A>(_ p: CharacterParser<A>) -> CharacterParser<A?> {
    return (pure { $0 } <*> p ) <|> pure(nil)
}

// return [A]{0,*}
func zeroOrMore<A>(_ p: CharacterParser<A>) -> CharacterParser<[A]> {
    return (prepend </> p <*> lazy { zeroOrMore(p) }) <|> pure([])
}

// return [A]{1,*}
func oneOrMore<A>(_ p: CharacterParser<A>) -> CharacterParser<[A]> {
    return prepend </> p <*> zeroOrMore(p)
}

// return [A]{1,*}
func greedy<A>(_ p: CharacterParser<A>) -> CharacterParser<A> {
    return CharacterParser { input in
        return greediestResults(p.parse(input))
    }
}

// return only the results that consume the most tokens
func greediestResults<Token, A>(_ results: AnySequence<(A, ArraySlice<Token>)>) -> AnySequence<(A, ArraySlice<Token>)> {
    guard let shortestTail = (results.map { $0.1.count }.min()) else {
        return results
    }
    return AnySequence(results.filter { $0.1.count == shortestTail })
}

// no matter what you pass, it returs A
func const<A,B>(_ x: A) -> (B) -> A {
    return { _ in x }
}

// parse a sequence of tokens
func parseCharacters(_ input: [Character]) -> CharacterParser<[Character]> {
    guard let (head, tail) = input.decompose else { return pure([]) }
    return prepend </> parseCharacter(head) <*> parseCharacters(tail)
}

// parse a sequence of characters matching string (and return string)
func parseString(_ string: String) -> CharacterParser<String> {
    return const(string) </> parseCharacters(Array(string))
}

// parser that always fails
func parseFail<A>() -> CharacterParser<A> {
    return CharacterParser { _ in emptySequence() }
}

// choose one of parsers from array
func oneOf<A>(_ parsers: [CharacterParser<A>]) -> CharacterParser<A> {
    return parsers.reduce(parseFail(), <|>)
}

func just<A>(_ p: CharacterParser<A>) -> CharacterParser<A> {
    return CharacterParser { input in
        let results = p.parse(input)
        return AnySequence(results.filter { $0.1.isEmpty })
    }
}
func pack<A>(_ p: CharacterParser<A>, start: Character, end: Character) -> CharacterParser<A> {
    return parseCharacter(start) *> p <* parseCharacter(end)
}



