(* Yoann Padioleau
 *
 * Copyright (C) 2002-2008 Yoann Padioleau
 * Copyright (C) 2014 Facebook
 *
 * This program is free software; you can redistribute it and/or
 * modify it under the terms of the GNU General Public License (GPL)
 * version 2 as published by the Free Software Foundation.
 * 
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * file license.txt for more details.
 *)
open Common

open Parser_cpp
open Token_views_cpp

module TH = Token_helpers_cpp
module PI = Parse_info
module TV = Token_views_cpp

(*****************************************************************************)
(* Prelude *)
(*****************************************************************************)

(*****************************************************************************)
(* Helpers *)
(*****************************************************************************)

let is_braceised = function
  | Braceised   _ -> true
  | BToken _ -> false


let look_like_argument tok_before xs =

  let xs = xs +> List.map (function
    | Tok ({t=TAnd ii} as record) -> Tok ({record with t=TMul ii})
    | x -> x
  )
  in

  (* split by comma so can easily check if have stuff like '*xx'
   * that takes the full argument
   *)
  let xxs = split_comma xs in

  let aux1 xs =
    match xs with
    | [] -> false

    (* *xx *)
    | [Tok{t=TMul _}; Tok{t=TIdent _}] -> true

    (* *(xx) *)
    | [Tok{t=TMul _}; Parens _] -> true

    (* TODO: xx * yy  and space = 1 between the 2 :) *)

    | _ -> false
  in
  
  let rec aux xs =
    match xs with
    | [] -> false
    (* a function call probably *)
    | Tok{t=TIdent _}::Parens _::xs -> 
        (* todo? look_like_argument recursively in Parens || aux xs ? *)
        true
    (* if have = ... then must stop, could be default parameter
     * of a method
     *)
    | Tok{t=TEq _}::xs ->
        false

    (* could be part of a type declaration *)
    | Tok {t=TOCro _}::Tok {t=TCCro _}::xs -> false

    | x::xs ->
        (match x with
        | Tok {t=(TInt _ | TFloat _ | TChar _ | TString _) } -> true
        | Tok {t=(Ttrue _ | Tfalse _) } -> true
        | Tok {t=(Tthis _)} -> true
        | Tok {t=(Tnew _ )} -> true
        | Tok {t= tok} when TH.is_binary_operator_except_star tok -> true
        | Tok {t=(TInc _ | TDec _)} -> true
        | Tok {t = (TDot _ | TPtrOp _ | TPtrOpStar _ | TDotStar _);_} -> true
        | Tok {t = (TOCro _)} -> true
        | Tok {t = (TWhy _ | TBang _)} -> true
        | _ -> aux xs
        )
  in
  (* todo? what if they contradict each other? if one say arg and
   * the other a parameter?
   *)
  xxs +> List.exists aux1 || aux xs

(* todo: pass1, look for const, etc
 * todo: pass2, look xx_t, xx&, xx*, xx**, see heuristics in typedef
 * 
 * Many patterns should mimic some heuristics in parsing_hack_typedef.ml
 *)
let look_like_parameter tok_before xs =
  let xs = xs +> List.map (function
    | Tok ({t=TAnd ii} as record) -> Tok ({record with t=TMul ii})
    | x -> x
  )
  in

  let xxs = split_comma xs in
  let aux1 xs =
    match xs with
    | [] -> false

    | [Tok {t=TIdent (s, _)}] when s =~ ".*_t$" -> true
    (* with DECLARE_BOOST_TYPE, but have some false positives
     * when people do xx* indexPtr = const_cast<>(indexPtr);
     * | [Tok {t=TIdent (s, _)}] when s =~ ".*Ptr$" -> true
     *)
    (* ugly!! *)
    | [Tok {t=TIdent (s, _)}] when s = "StringPiece" -> true

    (* xx* *)
    | [Tok {t=TIdent _}; Tok {t=TMul _}] -> true

    (* xx** *)
    | [Tok {t=TIdent _}; Tok {t=TMul _}; Tok {t=TMul _}] -> true

    (* xx * y   
     * TODO could be multiplication (or xx & yy)
     * TODO? could look if space around :) but because of the
     *  filtering of template and qualifier the no_space_between
     *  may not work here. May need lower level access to the list
     *  of TCommentSpace and their position.
     * 
     * C-s for parameter_decl in grammar to see that catch() is
     * a InParameter.
     *)
    | [Tok {t=TIdent _}; Tok {t=TMul _};Tok {t=TIdent _};] ->
      (match tok_before with 
      | Tok{t=(
            TIdent _ 
          | Tcatch _ 
          | TAt_catch _
          (* ugly: TIdent_Constructor interaction between past heuristics *)
          | TIdent_Constructor _
          | Toperator _
        )} -> true 
      | _ -> false
      )

    | _ -> false
  in

  let rec aux xs =
    match xs with
    | [] -> false

    (* xx yy *)
    | Tok {t=TIdent _}::Tok{t=TIdent _}::xs -> true

    | x::xs ->
        (match x with
        | Tok {t= tok} when TH.is_basic_type tok -> true
        | Tok {t = (Tconst _ | Tvolatile _)} -> true
        | Tok {t = (Tstruct _ | Tunion _ | Tenum _ | Tclass _)} -> true
        | _ -> 
            aux xs
        )
  in

  xxs +> List.exists aux1 || aux xs

let look_like_only_idents xs =
  xs +> List.for_all (function
  | Tok {t=(TComma _ | TIdent _)} -> true
  (* when have cast *)
  | Parens _ -> true
  | _ -> false
  )

(*****************************************************************************)
(* Main heuristics C++ *)
(*****************************************************************************)

(* assumes a view without: 
 * - template arguments, qualifiers, 
 * - comments and cpp directives 
 * - TODO public/protected/... ?
 *)
let set_context_tag_cplus groups =
  let rec aux xs =
  match xs with
  | [] -> ()
  (* class Foo {, also valid for struct (and union, hmmm) *)
  | Tok{t=(Tclass _ | Tstruct _ | Tunion _);_}::Tok{t=TIdent(s,_);_}
    ::(Braces(t1, body, t2) as braces)::xs
    ->
      [braces] +> TV.iter_token_multi (fun tok ->
        tok.TV.where <- (TV.InClassStruct s)::tok.TV.where;
      );
      aux (braces::xs)

  (* class Foo : ... { *)

  | Tok{t=Tclass _ | Tstruct _;_}::Tok{t=TIdent(s,_);_}
    ::Tok{t= TCol ii}::xs
    ->
      let (before, braces, after) =
        try 
          xs +> Common2.split_when (function
          | Braces _ -> true
          | _ -> false
          )
        with Not_found ->
          raise (UnclosedSymbol (spf "PB with split_when at %s"
                                    (Parse_info.string_of_info ii)))
      in
      aux before;
      [braces] +> TV.iter_token_multi (fun tok ->
        tok.TV.where <- (TV.InClassStruct s)::tok.TV.where;
      );
      aux [braces];
      aux after

  (* TODO = {   InInitializer *)

  (* TODO <...> InTemplateParam *)

  (* TODO enum xxx { InEnum *)

  (* TODO xx(...) {  InFunction (can have some try or const or throw after 
   * the paren *)

  (* need to look what was before to help the look_like_xxx heuristics 
   *
   * The order of the 3 rules below is important. We must first try
   * look_like_argument which has less FP than look_like_parameter
  *)
  | x::(Parens(t1, body, t2) as parens)::xs 
    when look_like_argument x body ->
      (*msg_context t1.t (TV.InArgument); *)
      [parens] +> TV.iter_token_multi (fun tok ->
        tok.TV.where <- (TV.InArgument)::tok.TV.where;
      );
      (* todo? recurse on body? *)
      aux [x];
      aux (parens::xs)

  (* special cases *)
  | (Tok{t=Toperator _} as tok1)::tok2::(Parens(t1, body, t2) as parens)::xs 
    when look_like_parameter tok1 body ->
      (* msg_context t1.t (TV.InParameter); *)
      [parens] +> TV.iter_token_multi (fun tok ->
        tok.TV.where <- (TV.InParameter)::tok.TV.where;
      );
      (* recurse on body? hmm if InParameter should not have nested 
       * stuff except when pass function pointer 
       *)
      aux [tok1;tok2];
      aux (parens::xs)

  | x::(Parens(t1, body, t2) as parens)::xs 
    when look_like_parameter x body ->
      (* msg_context t1.t (TV.InParameter); *)
      [parens] +> TV.iter_token_multi (fun tok ->
        tok.TV.where <- (TV.InParameter)::tok.TV.where;
      );
      (* recurse on body? hmm if InParameter should not have nested 
       * stuff except when pass function pointer 
       *)
      aux [x];
      aux (parens::xs)

  (* second tentative on InArgument, if xx(xx, yy, ww) where have only
   * identifiers, it's probably a constructed object!
   *)
  | Tok{t=TIdent _}::(Parens(t1, body, t2) as parens)::xs 
    when List.length body > 0 && look_like_only_idents body ->
      (* msg_context t1.t (TV.InArgument); *)
      [parens] +> TV.iter_token_multi (fun tok ->
        tok.TV.where <- (TV.InArgument)::tok.TV.where;
      );
      (* todo? recurse on body? *)
      aux (parens::xs)


  (* could be a cast too ... or what else? *)
  | x::(Parens(t1, body, t2) as parens)::xs ->
      (* let's default to something? hmm, no, got lots of regressions then 
       *  old: msg_context t1.t (TV.InArgument); ...
       *)
      aux [x];
      aux (parens::xs)
      

  | x::xs ->
      (match x with
      | Tok t -> ()
      | Parens (t1, xs, t2)
      | Braces (t1, xs, t2)
      | Angle  (t1, xs, t2)
         ->
          aux xs
      );
      aux xs
  in
  aux groups



(*****************************************************************************)
(* Context *)
(*****************************************************************************)
(* 
 * Most of the important contexts are introduced via some '{' '}'. To
 * disambiguate is it often enough to just look at a few tokens before the
 * '{'.
 * 
 * TODO harder now that have c++, can have function inside struct so need
 * handle all together. 
 * 
 * TODO So change token but do not recurse in
 * nested Braceised. maybe do via accumulator, don't use iter_token_brace.
 * 
 * TODO Also need remove the qualifier as they make
 * the sequence pattern matching more difficult.
 *)

let rec set_in_function_tag xs = 
 (* could try: ) { } but it can be the ) of a if or while, so 
  * better to base the heuristic on the position in column zero.
  * Note that some struct or enum or init put also their { in first column
  * but set_in_other will overwrite the previous InFunction tag.
  *)
 let rec aux xs = 
  match xs with
  | [] -> ()
(*TODOC++ext: now can have some const or throw between 
  => do a view that filter them first ?
*)

  (* ) { and the closing } is in column zero, then certainly a function *)
(*TODO1 col 0 not valid anymore with c++ nestedness of method *)
  | BToken ({t=TCPar _;_})::(Braceised (body, tok1, Some tok2))::xs 
      when tok1.col <> 0 && tok2.col = 0 -> 
      body +> List.iter (iter_token_brace (fun tok -> 
        tok.where <- InFunction::tok.where;
      ));
      aux xs

  | (BToken x)::xs -> aux xs

(*TODO1 not valid anymore with c++ nestedness of method *)
  | (Braceised (body, tok1, Some tok2))::xs 
      when tok1.col = 0 && tok2.col = 0 -> 
      body +> List.iter (iter_token_brace (fun tok -> 
        tok.where <- InFunction::tok.where;
      ));
      aux xs
  | Braceised (body, tok1, tok2)::xs -> 
      aux xs
 in
 aux xs

let rec set_in_other xs = 
  match xs with 
  | [] -> ()

  (* enum x { } *)
  | BToken ({t=Tenum _;_})::BToken ({t=TIdent _;_})
    ::Braceised(body, tok1, tok2)::xs 
  | BToken ({t=Tenum _;_})
    ::Braceised(body, tok1, tok2)::xs 
    -> 
      body +> List.iter (iter_token_brace (fun tok -> 
        tok.where <- InEnum::tok.where;
      ));
      set_in_other xs

  (* struct/union/class x { } *)
  | BToken ({t=tokstruct; _})::BToken ({t= TIdent (s,_); _})
    ::Braceised(body, tok1, tok2)::xs when TH.is_classkey_keyword tokstruct -> 
      body +> List.iter (iter_token_brace (fun tok -> 
        tok.where <- (InClassStruct s)::tok.where;
      ));
      set_in_other xs

  (* struct/union/class x : ... { } *)
  | BToken ({t= tokstruct; _})::BToken ({t=TIdent _; _})
    ::BToken ({t=TCol _;_})::xs when TH.is_classkey_keyword tokstruct -> 

      (try 
        let (before, elem, after) = Common2.split_when is_braceised xs in
        (match elem with 
        | Braceised(body, tok1, tok2) -> 
            body +> List.iter (iter_token_brace (fun tok -> 
              tok.where <- InInitializer::tok.where;
            ));
            set_in_other after
        | _ -> raise Impossible
        )
      with Not_found ->
        pr2 ("PB: could not find braces after struct/union/class x : ...");
      )

  (* = { } *)
  | BToken ({t=TEq _; _})
    ::Braceised(body, tok1, tok2)::xs -> 
      body +> List.iter (iter_token_brace (fun tok -> 
        tok.where <- InInitializer::tok.where;
      ));
      set_in_other xs


  (* recurse *)
  | BToken _::xs -> set_in_other xs
  | Braceised(body, tok1, tok2)::xs -> 
      body +> List.iter set_in_other;
      set_in_other xs

(* TODO: handle C++ context for real, and Parameter, and etc *)
let set_context_tag xs = 
  begin
    (* order is important *)
    set_in_function_tag xs;
    set_in_other xs;
  end