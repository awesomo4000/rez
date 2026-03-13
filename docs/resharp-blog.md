# RE#: how we built the world's fastest regex engine in F#

*by ian erik varatalu, February 22, 2026*

*Source: [https://iev.ee/blog/resharp-how-we-built-the-fastest-regex-in-fsharp/](https://iev.ee/blog/resharp-how-we-built-the-fastest-regex-in-fsharp/)*

---

around a year ago, we built [a regex engine](https://github.com/ieviev/resharp-dotnet) in F# that not only outperformed the ones in dotnet, but went above and beyond competing with every other industrial regex engine on a large set of industry-standard benchmarks. additionally, it supports the full set of boolean operators (union, intersection, complement) and even a form of context-aware lookarounds, which no other engine has while preserving `O(n)` search-time complexity. the paper was published at [POPL 2025](https://dl.acm.org/doi/abs/10.1145/3704837), and i figured it’s time to open source the engine and share the story behind it. consider it a much more casual and chatty version of the paper, with more focus on engineering aspects that went into it.

```fsharp
#r "nuget: resharp"

// find all matches
Resharp.Regex("hello.*world")
    .Matches("hello world!")

// intersection: contains "cat" AND "dog" AND is 5-15 chars long
Resharp.Regex(
    "_*cat_*&_*dog_*&_{5,15}")
    .Matches(input)

// complement: does not contain "1"
Resharp.Regex("~(_*1_*)")
    .Matches(input)
```

## brief introduction

almost every regex engine today descends from one of two approaches: Thompson’s NFA construction (1968) or backtracking (1994). Thompson-style engines (grep, RE2, Rust’s regex) give you linear-time guarantees but only support the “standard” fragment - `|` and `*`. backtracking engines (the rest, 95% chance the one you’re using) give you a mix of advanced features like backreferences, lookarounds.., but are unreliable, and can blow up to exponential time on adversarial inputs, which is a real security concern known as [ReDoS](https://en.wikipedia.org/wiki/ReDoS). to be more precise, this exponential behavior is not the only problem with backtracking engines - they also handle the OR (`|`) operator much slower, but let’s try to start with the big picture.

neither camp supports **intersection (&)** or **complement (~)**, which is a shame because it’s been known as early as 1964, but forgotten since then, before being brought to attention again in 2009, or as Owens, Reppy and Turon put it, it was [“lost in the sands of time”](https://www.cambridge.org/core/journals/journal-of-functional-programming/article/regularexpression-derivatives-reexamined/E5734B86DEB96C61C69E5CF3C4FB0AFA).. and forgotten again until [redgrep](https://github.com/google/redgrep) (2014) and later 2019, when it saw industrial use for credential scanning in [SRM](https://link.springer.com/chapter/10.1007/978-3-030-17462-0_24), albeit these operators were not exposed to the user back then. RE# is inspired by existing implementations of SRM and [.NET NonBacktracking engine](https://dl.acm.org/doi/10.1145/3591262) (2023), but in a way that hadn’t been done before, and with a lot of engineering work to make it fast and practical for real-world use cases.

a big goal of our paper was to really highlight how useful these operators really are. making it fast was more of a side-goal, so there would be less to complain about, as there was already a lot of disbelief, and we got comments such as it being a “theoretical curiosity”. i spent over a year experimenting with different approaches (there’s an initial draft on arXiv from 2023 where lookarounds had much worse complexity), but finally we found a combination that works extremely well **in practice**, and it helped me find a deeper intuition for what works both in theory and in the real world.

the result is RE#, the first general-purpose regex engine to support intersection, complement and lookarounds with linear-time guarantees (honorable mentions: Paul Wankadia’s redgrep has had intersection and complement with linear-time matching and derivatives for over a decade. also SBRE and LTRE which support both as well. RE# adds lookarounds on top & and ~.), and also the overall fastest regex engine on a large set of benchmarks. we also wanted to address some more things along the way, like returning **the correct matches** (the ones you meant, leftmost-longest), when the default semantics are given **by the PCRE implementation**. or put another way, “it’s correct if it does whatever the one that blows up and causes denial of service does”.

## Brzozowski derivatives

a core building block of `RE#` is the concept of regex derivatives, which is equally old, and equally forgotten until 2009 when it was rediscovered and 10 years later implemented in .NET for credential scanning.
**both derivatives and intersection/complement operators** originally came from a [1964 paper by Janusz Brzozowski](https://dl.acm.org/doi/abs/10.1145/321239.321249) (below).
![](/_astro/brzozowski.dCLhBsPw_1uURt4.webp)

don’t let the complex notation scare you - the core idea is **extremely simple**. the derivative of a regex `R` and a character `c` is simply whatever is left to match after removing the first character.

- derivative of `hello` and `h` is `ello`
- derivative of `abc` and `x` is `∅` (intuitively, the match failed here)
- derivative of `cat|dog` and `c` is `der(cat,c) | der(dog,c)`, which is `at|∅` and simplifies to `at`

![](/_astro/dfa1.CEb5C-8q_RPmFN.webp)

you can match a string by repeatedly taking derivatives for each character. when you’ve consumed the entire input, you check if the resulting regex accepts the empty string (is “nullable”). if yes, the original string matched.

what makes this elegant is that derivatives naturally extend to intersection and complement:

- derivative of `.*a.*&.*b.*` with `a` is `.*b.*`
- derivative of `~(abc)` with `a` is `~(bc)`

it just works. no special machinery needed. the boolean operators distribute over derivatives the same way union does. derivatives are such a powerful and interesting tool that i will dedicate a separate post to them, but the main point is that they give us a simple and uniform way to handle all regular language features, including intersection and complement.

Ken Thompson, perhaps one of the most well-known computer scientists of all time, created the [grandfather of all regex algorithms](https://dl.acm.org/doi/10.1145/363347.363387) in 1968, inspired by Brzozowski’s work, but only included OR (`|`) as a boolean operator. and somewhere in the process also changed the meaning of **union** to **alternation** by always choosing the left branch when both branches could match, but let’s skip ahead, we got plenty more tangents to avoid here.

the point i want to get to with Thompson’s paper is that the last few sentences of Thompson’s original paper actually **mention the possibility** of intersection and complement (below), but the funny thing is that this footnote has been forgotten for decades, and **no one ever followed through**.. and for the ones who tried, in fact, it wasn’t so easy in Thompson’s NFA framework at all, the devil is in the details.

![](/_astro/thompson.DxEHCRM-_ZHb6Pt.webp)

## separation of concerns

the biggest gain from `&` and `~` is that they let you mix and match regexes. instead of writing a single spaghetti monster regex that tries to do everything, you can break it down into smaller, simpler pieces and then combine them with boolean operators. this makes your regexes easier to read, write and maintain. this is best illustrated in the web app that came with the paper ([https://ieviev.github.io/resharp-webapp/](https://ieviev.github.io/resharp-webapp/)) where you can visually see how the different components of a regex are combined, and how they contribute to the final match.

as we wrote in the paper, RE# lets you write small fragments of regexes that **describe individual properties** of the matches you want, and then **combine them** with boolean operators to get the final result (below).

```md
- `_*` = any string
- `a_*` = any string that starts with 'a'
- `_*a` = any string that ends with 'a'
- `_*a_*` = any string that contains 'a'
- `~(_*a_*)` = any string that does NOT contain 'a'
- `(_*a_*)&~(_*b_*)` = any string that contains 'a' AND does not contain 'b'
- `(?`.
the Teddy multi-string search algorithm was recently added to .NET 9, which boosted our results quite a bit. writing in F# means direct access to all of this with zero interop cost. not to mention RyuJIT has codegen comparable to native languages.

we also have a Rust implementation of the core engine, but it’s there because we want a native library without dependencies and good UTF-8 support, not because it’s necessarily faster. in fact, the F# version is faster than the Rust version - .NET has an effortless way to vectorize regexes with `SearchValues`, and our implementation is able to detect and utilize these opportunities when most other engines can’t. replicating what .NET gives you for free would take considerable effort, and i haven’t done that in Rust yet - especially since many existing SIMD subroutines only work left to right, while .NET also provides right-to-left variants needed for our bidirectional matching.

the code doesn’t look like idiomatic F#. the hot paths are full of mutable state, spans, and memory-pooled arrays. earlier versions even used raw pointers. F# is first and foremost a functional language, and bending it toward low-level systems programming took some effort. but it does support the constructs you need when performance matters, and the language really shines where it counts most for this project: expressing the algorithms themselves. the core data structure for regexes is a recursive discriminated union, which is a natural fit for F#‘s algebraic data types:

```fsharp
type RegexNodeId = int32
[]
type RegexNode =
    | Singleton of 'tset
    | Or of nodes: RegexNodeId[]
    | And of nodes: RegexNodeId[]
    | Not of node: RegexNodeId
    | Loop of node: RegexNodeId * low: int * up: int
    | Concat of head: RegexNodeId * tail: RegexNodeId
    | LookAround of node: RegexNodeId * lookBack: bool * ...
    | Begin
    | End
```

the derivative function, the nullability check, the rewrite rules - they’re all structural recursion over this type. F#‘s pattern matching makes this natural to write and natural to read. and when you need raw performance in the hot loop, [SRTP](https://learn.microsoft.com/en-us/dotnet/fsharp/language-reference/generics/statically-resolved-type-parameters), inlining, and even raw embedded IL are right there.

![](/_astro/fsh1.B7fOPtAg_2wmmK.webp)

## semantics, what should a regex engine do when there are multiple possible matches?

this is a surprisingly controversial topic, and one that is often overlooked in academic research, and not well known in the industry.

what substrings does the regex `(a|ab)+` match in the following input?

```plaintext
aababaabab
```

think about it:

- the full string `aababaabab` is a valid match: `a·ab·ab·a·ab·ab`

a backtracking engine (meaning most of them) gives you 4 matches here:

aababaabab

RE# gives you 1 match - the entire string:

aababaabab

this isn’t just an academic curiosity. flip the alternation order to `(ab|a)+` and suddenly PCRE matches the entire string! the `|` operator in backtracking engines is **ordered** - it’s not union, it’s “try left first”. the order of branches changes the result, which means `|` is not commutative. `a|b` and `b|a` can give different matches.

this breaks things that should obviously work. take the distributive law: `(a|ab)(c|b)` and `(a|ab)c|(a|ab)b` are logically the same pattern - you can verify this yourself by just expanding the terms. but in PCRE, the first matches `ab` in the input `abc`, while the second matches `abc`. two equivalent patterns, two different results.

and this is the crux of why we care: **extended operators do not make sense with an ordered OR**. if `|` isn’t commutative, then boolean algebra falls apart. `A & B` is supposed to equal `B & A`. `~~A` is supposed to equal `A`. these identities rely on `|` being true union, not “try left first”. so if you want `&` and `~` to work correctly, you need commutative semantics. it’s not a style choice, it’s a mathematical necessity. and surprisingly also a reason for our amazing benchmark results - leftmost-longest lets you **simplify** your regexes without changing the matches, which i will elaborate on in another post, but for now just take my word for it that this is a huge deal for performance.

the standard that defines leftmost-longest is called POSIX, and despite the name suggesting it’s specific to unix, it’s really just the most natural interpretation: among all matches starting at the leftmost position, pick the longest one. this is what `grep` does, what `awk` does, and what RE# does.

how does RE# find the leftmost-longest match efficiently? remember the bidirectional scanning we mentioned earlier - run the DFA right to left to find all possible match **starts**, then run a reversed DFA left to right to find the **ends**. the leftmost start paired with the rightmost end (starting from that particular match) gives you leftmost-longest. two linear DFA scans, no backtracking, no ambiguity.

here’s a subtle but important consequence: in RE#, rewriting your regex using boolean algebra is always safe. factor out common prefixes, distribute over union, apply de Morgan’s laws - the matches won’t change. your regex is a specification of a set of strings, and the engine faithfully finds the leftmost-longest element of that set in the input. no surprises from alternation order, no “well it depends on how PCRE explores this search tree”. just set theory.

there’s a ton of bugs in industrial applications that come from this kind of “it depends” behavior, and it’s a nightmare for testing and maintenance. even LLMs get this wrong all the time because they’ve been **trained for an eternity of people getting it wrong all the time** - you wouldn’t believe the types of human-hallucinated answers there are out there on stack overflow. perhaps one last thing to say here is that leftmost-longest can express every single pattern that leftmost-greedy can. it is a more general form. want to return the same results from `(a|ab)+` as PCRE? just rewrite it as `(a)+` - that’s what it is. the very fact that there is a difference at all means that there was a bug in the PCRE pattern, `ab` is an unreachable branch.

## finding all matches, the llmatch algorithm implementation

i want it to be understood that “finding **the (1)** match” with our llmatch algorithm is a little silly - why would we start matching backwards if we want the **first match**. it makes absolutely no sense. you must be out of your mind to start reading a terabyte log file from the end to find the match on the first line.

but our algorithm is not for “the (1)” match, it’s designed to mark-and-sweep through **all matches** in the input, and looking back, the paper does not highlight the importance of this as much as it should. without pointing this out, we would have the slowest first match algorithm in the world.

it was initially counterintuitive and hard for me to accept as well, but let me really illustrate how it works. in the paper, we describe an example where we want to find author names using context assertions, described roughly as follows:

- located between `{` and `}`
- preceded by the word “author” on the same line

![](/_astro/llmatch1.DsecghIu_12HYFf.webp)

and the magic here is that we can do this with **zero back-and-forth movement**. we find the matches with two linear scans, one right to left to mark exactly where the matches start, and one left to right to eliminate overlap. right to left sweep marks **all matches in a single pass**. it’s completely deterministic, every possible future has been accounted for, and we just let the automaton do its thing.

start from the end of the text (below), and as you move left, you will encounter a lot of “possible matches” that are waiting for confirmation. all the heavy computation has already been done in the states of the automaton, which are reused for subsequent characters, so **after initial wind-up time**, you **will not create any new states**, just reusing the same ones over and over again, and marking the positions of matches as you go.

![](/_astro/llmatch2.D_4V9GfY_14l8Jo.webp)

this is a very powerful technique, and it is the main reason why we are so fast on the benchmarks, because by the time we confirm a match, both the lookbehind and lookahead have already been matched - we report matches **retroactively** once all the context is known, instead of trying to look into the future or backtracking to the past or keeping track of NFA states. this is a very different way of thinking about regex matching, and it took me a while to wrap my head around it, but once you see it in action, i hope you appreciate how elegant and efficient it is.

and of course for `IsMatch` there is no difference in which direction you go, you can just stop at the first match and return true. in fact lookarounds aren’t necessary for `IsMatch` at all, they are indistinguishable from concatenation. `a(?=b)` is just `ab` for the purposes of `IsMatch` and `a(?=.*b)(?=.*c)` is just `a(.*b_*&.*c_*)` - the lookarounds only come into play when you want to know the position of the match, and what is around it. if you happen to use lookarounds in an `IsMatch` pattern today, consider RE# intersections a faster drop-in replacement with identical semantics.

## what about the other linear lookaround approaches?

two other recent works tackle linear-time lookaround matching: [Mamouras et al. (POPL 2024)](https://dl.acm.org/doi/10.1145/3632934) and [linearJS by Barriere et al. (PLDI 2024)](https://dl.acm.org/doi/10.1145/3656431). both are interesting contributions that approach the problem very differently from us, and both support arbitrary lookarounds with nesting, which is a nice feature to have.

i haven’t found an implementation of the first one ([update: a Haskell implementation by a different author exists](https://github.com/Agnishom/lregex)). the second targets javascript and should be available in node/chromium at some point. running `/(a+)*b$/.test("aaaaaaaaaaaaaaaaaaaaaaaaaaaaaba")` in my browser console still makes the fans spin for 10 seconds, so i’m fairly sure it hasn’t shipped yet. without implementations and benchmarks to compare against, i can only comment on the theoretical differences.

both of these approaches use NFAs under the hood, which means `O(m * n)` matching. our approach is fundamentally different: we encode lookaround information directly in the automaton via derivatives, which gives us `O(n)` matching with a small constant. the trade-off is that we restrict lookarounds to a normalized form `(?  [   
back to all posts
](/blog)