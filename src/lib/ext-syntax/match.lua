----------------------------------------------------------------------
-- Metalua samples:  $Id$
--
-- Summary: Structural pattern matching for metalua ADT.
--
----------------------------------------------------------------------
--
-- Copyright (c) 2006, Fabien Fleutot <metalua@gmail.com>.
--
-- This software is released under the MIT Licence, see licence.txt
-- for details.
--
--------------------------------------------------------------------------------
--
-- This extension, borrowed from ML dialects, allows in a single operation to
-- analyze the structure of nested ADT, and bind local variables to subtrees
-- of the analyzed ADT before executing a block of statements chosen depending
-- on the tested term's structure.
--
-- The general form of a pattern matching statement is:
--
-- match <tested_term> with
-- | <pattern_1_1> | <pattern_1_2> | <pattern_1_3> -> <block_1>
-- | <pattern_2> -> <block_2>
-- | <pattern_3_1> | <pattern_3_2> if <some_condition> -> <block_3> 
-- end
-- 
-- If one of the patterns <pattern_1_x> accurately describes the
-- structure of <tested_term>, then <block_1> is executed (and no
-- other block of the match statement is tested). If none of
-- <pattern_1_x> patterns mathc <tested_term>, but <pattern_2> does,
-- then <block_2> is evaluated before exiting. If no pattern matches,
-- the whole <match> statemetn does nothing. If more than one pattern
-- matches, the first one wins.
-- 
-- When an additional condition, introduced by [if], is put after
-- the patterns, this condition is evaluated if one of the patterns matches,
-- and the case is considered successful only if the condition returns neither
-- [nil] nor [false].
--
-- Terminology
-- ===========
--
-- The whole compound statement is called a match; Each schema is
-- called a pattern; Each sequence (list of patterns, optional guard,
-- statements block) is called a case.
--
-- Patterns
-- ========
-- Patterns can consist of:
--
-- - numbers, booleans, strings: they only match terms equal to them
--
-- - variables: they match everything, and bind it, i.e. the variable
--   will be set to the corresponding tested value when the block will
--   be executed (if the whole pattern and the guard match). If a
--   variable appears more than once in a single pattern, all captured
--   values have to be equal, in the sense of the "==" operator.
--
-- - tables: a table matches if all these conditions are met:
--   * the tested term is a table;
--   * all of the pattern's keys are strings or integer or implicit indexes;
--   * all of the pattern's values are valid patterns, except maybe the
--     last value with implicit integer key, which can also be [...];
--   * every value in the tested term is matched by the corresponding
--     sub-pattern;
--   * There are as many integer-indexed values in the tested term as in
--     the pattern, or there is a [...] at the end of the table pattern.
-- 
-- Pattern examples
-- ================
--
-- Pattern { 1, a } matches term { 1, 2 }, and binds [a] to [2].
-- It doesn't match term { 1, 2, 3 } (wrong number of parameters).
--
-- Pattern { 1, a, ... } matches term { 1, 2 } as well as { 1, 2, 3 }
-- (the trailing [...] suppresses the same-length condition)
-- 
-- `Foo{ a, { bar = 2, b } } matches `Foo{ 1, { bar = 2, "THREE" } }, 
-- and binds [a] to [1], [b] to ["THREE"] (the syntax sugar for [tag] fields
-- is available in patterns as well as in regular terms).
--
-- Implementation hints
-- ====================
--
-- Since the control flow quickly becomes hairy, it's implemented with
-- gotos and labels. [on_success] holds the label name where the
-- control flow must go when the currently parsed pattern
-- matches. [on_failure] is the next position to reach if the current
-- pattern mismatches: either the next pattern in a multiple-patterns
-- case, or the next case when parsing the last pattern of a case, or
-- the end of the match code for the last pattern of the last case.
--
-- [case_vars] is the list of variables created for the current
-- case. It's kept to generate the local variables declaration.
-- [pattern_vars] is also kept, to detect non-linear variables
-- (variables which appear more than once in a given pattern, and
-- therefore require an == test).
--
--------------------------------------------------------------------------------
--
-- TODO:
--
-- [CHECK WHETHER IT'S STILL TRUE AFTER TESTS INVERSION]
-- - Optimize jumps: the bytecode generated often contains several
--   [OP_JMP 1] in a row, which is quite silly. That might be due to the
--   implementation of [goto], but something can also probably be done
--   in pattern matching implementation.
--
----------------------------------------------------------------------

----------------------------------------------------------------------
-- Convert a tested term and a list of (pattern, statement) pairs
-- into a pattern-matching AST.
----------------------------------------------------------------------
local function match_builder (tested_terms_list, cases)

   local local_vars = { }
   local var = |n| `Id{ "$v" .. n }
   local on_failure -- current target upon pattern mismatch

   local literal_tags = { String=1, Number=1, Boolean=1 }

   local current_code -- list where instructions are accumulated
   local pattern_vars -- list where local vars are accumulated
   local case_vars    -- list where local vars are accumulated

   -------------------------------------------------------------------
   -- Accumulate statements in [current_code]
   -------------------------------------------------------------------
   local function acc (x) 
      --printf ("%s", disp.ast (x))
      table.insert (current_code, x) end
   local function acc_test (it) -- the test must fail for match to succeeed.
      acc +{stat: if -{it} then -{`Goto{ on_failure }} end } end
   local function acc_assign (lhs, rhs)
      local_vars[lhs[1]] = true
      acc (`Let{ {lhs}, {rhs} }) end

   -------------------------------------------------------------------
   -- Set of variables bound in the current pattern, to find
   -- non-linear patterns.
   -------------------------------------------------------------------
   local function handle_id (id, val)
      assert (id.tag=="Id")
      if id[1] == "_" then 
         -- "_" is used as a dummy var ==> no assignment, no == checking
         case_vars["_"] = true
      elseif pattern_vars[id[1]] then 
         -- This var is already bound ==> test for equality
         acc_test +{ -{val} ~= -{id} }
      else
         -- Free var ==> bind it, and remember it for latter linearity checking
         acc_assign (id, val) 
         pattern_vars[id[1]] = true
         case_vars[id[1]]    = true
      end
   end

   -------------------------------------------------------------------
   -- Turn a pattern into a list of tests and assignments stored into
   -- [current_code]. [n] is the depth of the subpattern into the
   -- toplevel pattern; [pattern] is the AST of a pattern, or a
   -- subtree of that pattern when [n>0].
   -------------------------------------------------------------------
   local function pattern_builder (n, pattern)
      local v = var(n)
      if literal_tags[pattern.tag]  then acc_test +{ -{v} ~= -{pattern} }
      elseif "Id"    == pattern.tag then handle_id (pattern, v)
      elseif "Op"    == pattern.tag and "div" == pattern[1] then
         local n2 = n>0 and n+1 or 1
         local _, regexp, sub_pattern = unpack(pattern)
         if sub_pattern.tag=="Id" then sub_pattern = `Table{ sub_pattern } end
         -- Sanity checks --
         assert (regexp.tag=="String", 
                 "Left hand side operand for '/' in a pattern must be "..
                 "a literal string representing a regular expression")
         assert (sub_pattern.tag=="Table",
                 "Right hand side operand for '/' in a pattern must be "..
                 "an identifier or a list of identifiers")
         for x in ivalues(sub_pattern) do
            assert (x.tag=="Id" or x.tag=='Dots',
                 "Right hand side operand for '/' in a pattern must be "..
                 "a list of identifiers")
         end

         -- Can only match strings
         acc_test +{ type(-{v}) ~= 'string' }
         -- put all captures in a list
         local capt_list  = +{ { string.strmatch(-{v}, -{regexp}) } }
         -- save them in a var_n for recursive decomposition
         acc +{stat: local -{var(n2)} = -{capt_list} }
         -- was capture successful?
         acc_test +{ not next (-{var(n2)}) }
         pattern_builder (n2, sub_pattern)
      elseif "Table" == pattern.tag then
         local seen_dots, len = false, 0
         acc_test +{ type( -{v} ) ~= "table" } 
         for i = 1, #pattern do
            local key, sub_pattern
            if pattern[i].tag=="Key" then -- Explicit key
               key, sub_pattern = unpack (pattern[i])
               assert (literal_tags[key.tag], "Invalid key")
            else -- Implicit key
               len, key, sub_pattern = len+1, `Number{ len+1 }, pattern[i]
            end
            assert (not seen_dots, "Wrongly placed `...' ")
            if sub_pattern.tag == "Id" then 
               -- Optimization: save a useless [ v(n+1)=v(n).key ]
               handle_id (sub_pattern, `Index{ v, key })
               if sub_pattern[1] ~= "_" then 
                  acc_test +{ -{sub_pattern} == nil } 
               end
            elseif sub_pattern.tag == "Dots" then
               -- Remember to suppress arity checking
               seen_dots = true
            else
               -- Business as usual:
               local n2 = n>0 and n+1 or 1
               acc_assign (var(n2), `Index{ v, key })
               pattern_builder (n2, sub_pattern)
            end
         end
         if not seen_dots then -- Check arity
            acc_test +{ #-{v} ~= -{`Number{len}} }
         end
      else 
         error ("Invalid pattern: "..table.tostring(pattern, "nohash"))
      end
   end

   local end_of_match = mlp.gensym "_end_of_match"
   local arity = #tested_terms_list
   local x = `Local{ { }, { } }
   for i=1,arity do 
      x[1][i]=var(-i)
      x[2][i]= tested_terms_list[i]
   end
   local complete_code = `Do{ x }

   -- Foreach [{patterns, guard, block}]:
   for i = 1, #cases do
      local patterns, guard, block = unpack (cases[i])
   
      -- Reset accumulators
      local local_decl_stat = { }
      current_code = `Do{ `Local { local_decl_stat, { } } } -- reset code accumulator
      case_vars = { }
      table.insert (complete_code, current_code)

      local on_success = mlp.gensym "_on_success" -- 1 success target per case

      -----------------------------------------------------------
      -- Foreach [pattern] in [patterns]:
      -- on failure go to next pattern if any, 
      -- next case if no more pattern in current case.
      -- on success (i.e. no [goto on_failure]), go to after last pattern test
      -- if there is a guard, test it before the block: it's common to all patterns,
      -----------------------------------------------------------
      for j = 1, #patterns do
         if #patterns[j] ~= arity then 
            error( "Invalid match: pattern has only "..
                   #patterns[j].." elements, "..
                   arity.." were expected")
         end
         pattern_vars = { }
         on_failure = mlp.gensym "_on_failure" -- 1 failure target per pattern
         
         for k = 1, arity do pattern_builder (-k, patterns[j][k]) end
         if j<#patterns then 
            acc (`Goto{on_success}) 
            acc (`Label{on_failure}) 
         end
      end
      acc (`Label{on_success})
      if guard then acc_test (`Op{ "not", guard}) end
      acc (block)
      acc (`Goto{end_of_match}) 
      acc (`Label{on_failure})

      -- fill local variables declaration:
      local v1 = var(1)[1]
      for k, _ in pairs(case_vars) do
         if k[1] ~= v1 then table.insert (local_decl_stat, `Id{k}) end
      end

   end
   acc +{error "mismatch"} -- cause a mismatch error after last case failed
   table.insert(complete_code, `Label{ end_of_match })
   return complete_code
end

----------------------------------------------------------------------
-- Sugar: add the syntactic extension that makes pattern matching
--        pleasant to read and write.
----------------------------------------------------------------------

mlp.lexer:add{ "match", "with", "->" }
mlp.block.terminators:add "|"

mlp.stat:add{ name = "match statement",
   "match", mlp.expr_list, "with",
   gg.optkeyword "|",
   gg.list{ name = "match cases list",
      primary     = gg.sequence{ name = "match case",
         gg.list{ name = "patterns",
            primary = mlp.expr_list,
            separators = "|",
            terminators = { "->", "if" } },
         gg.onkeyword{ "if", mlp.expr, consume = true },
         "->",
         mlp.block },
      separators  = "|",
      terminators = "end" },
   "end",
   builder = |x| match_builder (x[1], x[3]) }
