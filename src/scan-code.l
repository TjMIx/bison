/* Bison Action Scanner                             -*- C -*-

   Copyright (C) 2006 Free Software Foundation, Inc.

   This file is part of Bison, the GNU Compiler Compiler.

   This program is free software; you can redistribute it and/or modify
   it under the terms of the GNU General Public License as published by
   the Free Software Foundation; either version 2 of the License, or
   (at your option) any later version.

   This program is distributed in the hope that it will be useful,
   but WITHOUT ANY WARRANTY; without even the implied warranty of
   MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
   GNU General Public License for more details.

   You should have received a copy of the GNU General Public License
   along with this program; if not, write to the Free Software
   Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA
   02110-1301  USA
*/

%option debug nodefault nounput noyywrap never-interactive
%option prefix="code_" outfile="lex.yy.c"

%{
/* Work around a bug in flex 2.5.31.  See Debian bug 333231
   <http://bugs.debian.org/cgi-bin/bugreport.cgi?bug=333231>.  */
#undef code_wrap
#define code_wrap() 1

#define FLEX_PREFIX(Id) code_ ## Id
#include "flex-scanner.h"

#include "complain.h"
#include "reader.h"
#include "getargs.h"
#include <assert.h>
#include <get-errno.h>
#include <quote.h>

#include "scan-code.h"

/* The current calling start condition: SC_RULE_ACTION or
   SC_SYMBOL_ACTION. */
# define YY_DECL char *code_lex (int sc_context, symbol_list *rule)
YY_DECL;

#define YY_USER_ACTION  location_compute (loc, &loc->end, yytext, yyleng);

static void handle_action_dollar (symbol_list *rule, char *cp,
				  location dollar_loc);
static void handle_action_at (symbol_list *rule, char *cp, location at_loc);
static location the_location;
static location *loc = &the_location;

/* True if an untyped $$ or $n was seen.  */
static bool untyped_var_seen;
%}
 /* C and C++ comments in code. */
%x SC_COMMENT SC_LINE_COMMENT
 /* Strings and characters in code. */
%x SC_STRING SC_CHARACTER
 /* Whether in a rule or symbol action.  Specifies the translation
    of $ and @.  */
%x SC_RULE_ACTION SC_SYMBOL_ACTION


/* POSIX says that a tag must be both an id and a C union member, but
   historically almost any character is allowed in a tag.  We disallow
   NUL and newline, as this simplifies our implementation.  */
tag	 [^\0\n>]+

/* Zero or more instances of backslash-newline.  Following GCC, allow
   white space between the backslash and the newline.  */
splice	 (\\[ \f\t\v]*\n)*

%%

%{
  /* Nesting level of the current code in braces.  */
  int braces_level IF_LINT (= 0);

  /* This scanner is special: it is invoked only once, henceforth
     is expected to return only once.  This initialization is
     therefore done once per action to translate. */
  assert (sc_context == SC_SYMBOL_ACTION
	  || sc_context == SC_RULE_ACTION
	  || sc_context == INITIAL);
  BEGIN sc_context;
%}

  /*------------------------------------------------------------.
  | Scanning a C comment.  The initial `/ *' is already eaten.  |
  `------------------------------------------------------------*/

<SC_COMMENT>
{
  "*"{splice}"/"  STRING_GROW; BEGIN sc_context;
}


  /*--------------------------------------------------------------.
  | Scanning a line comment.  The initial `//' is already eaten.  |
  `--------------------------------------------------------------*/

<SC_LINE_COMMENT>
{
  "\n"		 STRING_GROW; BEGIN sc_context;
  {splice}	 STRING_GROW;
}


  /*--------------------------------------------.
  | Scanning user-code characters and strings.  |
  `--------------------------------------------*/

<SC_CHARACTER,SC_STRING>
{
  {splice}|\\{splice}.	STRING_GROW;
}

<SC_CHARACTER>
{
  "'"		STRING_GROW; BEGIN sc_context;
}

<SC_STRING>
{
  "\""		STRING_GROW; BEGIN sc_context;
}


<SC_RULE_ACTION,SC_SYMBOL_ACTION>{
  "'" {
    STRING_GROW;
    BEGIN SC_CHARACTER;
  }
  "\"" {
    STRING_GROW;
    BEGIN SC_STRING;
  }
  "/"{splice}"*" {
    STRING_GROW;
    BEGIN SC_COMMENT;
  }
  "/"{splice}"/" {
    STRING_GROW;
    BEGIN SC_LINE_COMMENT;
  }
}

<SC_RULE_ACTION>
{
  "$"("<"{tag}">")?(-?[0-9]+|"$")   handle_action_dollar (rule, yytext, *loc);
  "@"(-?[0-9]+|"$")		    handle_action_at (rule, yytext, *loc);

  "$"  {
    warn_at (*loc, _("stray `$'"));
    obstack_sgrow (&obstack_for_string, "$][");
  }
  "@"  {
    warn_at (*loc, _("stray `@'"));
    obstack_sgrow (&obstack_for_string, "@@");
  }

  "{"  STRING_GROW; ++braces_level;
  "}"  {
    bool outer_brace = --braces_level < 0;

    /* As an undocumented Bison extension, append `;' before the last
       brace in braced code, so that the user code can omit trailing
       `;'.  But do not append `;' if emulating Yacc, since Yacc does
       not append one.

       FIXME: Bison should warn if a semicolon seems to be necessary
       here, and should omit the semicolon if it seems unnecessary
       (e.g., after ';', '{', or '}', each followed by comments or
       white space).  Such a warning shouldn't depend on --yacc; it
       should depend on a new --pedantic option, which would cause
       Bison to warn if it detects an extension to POSIX.  --pedantic
       should also diagnose other Bison extensions like %yacc.
       Perhaps there should also be a GCC-style --pedantic-errors
       option, so that such warnings are diagnosed as errors.  */
    if (outer_brace && ! yacc_flag)
      obstack_1grow (&obstack_for_string, ';');

    STRING_GROW;
  }
}

<SC_SYMBOL_ACTION>
{
  "$$"   obstack_sgrow (&obstack_for_string, "]b4_dollar_dollar[");
  "@$"   obstack_sgrow (&obstack_for_string, "]b4_at_dollar[");
}


  /*-----------------------------------------.
  | Escape M4 quoting characters in C code.  |
  `-----------------------------------------*/

<*>
{
  \$	obstack_sgrow (&obstack_for_string, "$][");
  \@	obstack_sgrow (&obstack_for_string, "@@");
  \[	obstack_sgrow (&obstack_for_string, "@{");
  \]	obstack_sgrow (&obstack_for_string, "@}");
}

  /*-----------------------------------------------------.
  | By default, grow the string obstack with the input.  |
  `-----------------------------------------------------*/

<*>.|\n	STRING_GROW;

 /* End of processing. */
<*><<EOF>>	 {
                   obstack_1grow (&obstack_for_string, '\0');
		   return obstack_finish (&obstack_for_string);
                 }

%%

/* Keeps track of the maximum number of semantic values to the left of
   a handle (those referenced by $0, $-1, etc.) are required by the
   semantic actions of this grammar. */
int max_left_semantic_context = 0;


/*------------------------------------------------------------------.
| TEXT is pointing to a wannabee semantic value (i.e., a `$').      |
|                                                                   |
| Possible inputs: $[<TYPENAME>]($|integer)                         |
|                                                                   |
| Output to OBSTACK_FOR_STRING a reference to this semantic value.  |
`------------------------------------------------------------------*/

static void
handle_action_dollar (symbol_list *rule, char *text, location dollar_loc)
{
  const char *type_name = NULL;
  char *cp = text + 1;
  symbol_list *effective_rule;
  int effective_rule_length;

  if (rule->midrule_parent_rule)
    {
      effective_rule = rule->midrule_parent_rule;
      effective_rule_length = rule->midrule_parent_rhs_index - 1;
    }
  else
    {
      effective_rule = rule;
      effective_rule_length = symbol_list_length (rule->next);
    }

  /* Get the type name if explicit. */
  if (*cp == '<')
    {
      type_name = ++cp;
      while (*cp != '>')
	++cp;
      *cp = '\0';
      ++cp;
      if (untyped_var_seen)
	complain_at (dollar_loc, _("explicit type given in untyped grammar"));
      tag_seen = true;
    }

  if (*cp == '$')
    {
      if (!type_name)
	type_name = symbol_list_n_type_name_get (rule, dollar_loc, 0);

      if (!type_name)
	{
	  if (union_seen | tag_seen)
	    {
	      if (rule->midrule_parent_rule)
		complain_at (dollar_loc,
			     _("$$ for the midrule at $%d of `%s'"
			       " has no declared type"),
			     rule->midrule_parent_rhs_index,
			     effective_rule->content.sym->tag);
	      else
		complain_at (dollar_loc, _("$$ of `%s' has no declared type"),
			     rule->content.sym->tag);
	    }
	  else
	    untyped_var_seen = true;
	  type_name = "";
	}

      obstack_fgrow1 (&obstack_for_string,
		      "]b4_lhs_value([%s])[", type_name);
      rule->used = true;
    }
  else
    {
      long int num = strtol (cp, NULL, 10);

      if (1 - INT_MAX + effective_rule_length <= num
	  && num <= effective_rule_length)
	{
	  int n = num;
	  if (max_left_semantic_context < 1 - n)
	    max_left_semantic_context = 1 - n;
	  if (!type_name && 0 < n)
	    type_name =
	      symbol_list_n_type_name_get (effective_rule, dollar_loc, n);
	  if (!type_name)
	    {
	      if (union_seen | tag_seen)
		complain_at (dollar_loc, _("$%d of `%s' has no declared type"),
			     n, effective_rule->content.sym->tag);
	      else
		untyped_var_seen = true;
	      type_name = "";
	    }

	  obstack_fgrow3 (&obstack_for_string,
			  "]b4_rhs_value(%d, %d, [%s])[",
			  effective_rule_length, n, type_name);
	  symbol_list_n_used_set (effective_rule, n, true);
	}
      else
	complain_at (dollar_loc, _("integer out of range: %s"), quote (text));
    }
}


/*------------------------------------------------------.
| TEXT is a location token (i.e., a `@...').  Output to |
| OBSTACK_FOR_STRING a reference to this location.      |
`------------------------------------------------------*/

static void
handle_action_at (symbol_list *rule, char *text, location at_loc)
{
  char *cp = text + 1;
  locations_flag = true;
  int effective_rule_length;

  if (rule->midrule_parent_rule)
    effective_rule_length = rule->midrule_parent_rhs_index - 1;
  else
    effective_rule_length = symbol_list_length (rule->next);

  if (*cp == '$')
    obstack_sgrow (&obstack_for_string, "]b4_lhs_location[");
  else
    {
      long int num = strtol (cp, NULL, 10);

      if (1 - INT_MAX + effective_rule_length <= num
	  && num <= effective_rule_length)
	{
	  int n = num;
	  obstack_fgrow2 (&obstack_for_string, "]b4_rhs_location(%d, %d)[",
			  effective_rule_length, n);
	}
      else
	complain_at (at_loc, _("integer out of range: %s"), quote (text));
    }
}


/*-------------------------.
| Initialize the scanner.  |
`-------------------------*/

/* Translate the dollars and ats in \a a, whose location is \a l.  The
   translation is for \a rule, in the context \a sc_context
   (SC_RULE_ACTION, SC_SYMBOL_ACTION, INITIAL).  */

static char *
translate_action (int sc_context, symbol_list *rule, const char *a, location l)
{
  char *res;
  static bool initialized = false;
  if (!initialized)
    {
      obstack_init (&obstack_for_string);
      /* The initial buffer, never used. */
      yy_delete_buffer (YY_CURRENT_BUFFER);
      yy_flex_debug = 0;
      initialized = true;
    }

  loc->start = loc->end = l.start;
  yy_switch_to_buffer (yy_scan_string (a));
  res = code_lex (sc_context, rule);
  yy_delete_buffer (YY_CURRENT_BUFFER);

  return res;
}

char *
translate_rule_action (symbol_list *rule)
{
  return translate_action (SC_RULE_ACTION, rule, rule->action,
			   rule->action_location);
}

char *
translate_symbol_action (const char *a, location l)
{
  return translate_action (SC_SYMBOL_ACTION, NULL, a, l);
}

char *
translate_code (const char *a, location l)
{
  return translate_action (INITIAL, NULL, a, l);
}

/*-----------------------------------------------.
| Free all the memory allocated to the scanner.  |
`-----------------------------------------------*/

void
code_scanner_free (void)
{
  obstack_free (&obstack_for_string, 0);
  /* Reclaim Flex's buffers.  */
  yy_delete_buffer (YY_CURRENT_BUFFER);
}