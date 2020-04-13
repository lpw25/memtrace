(* A generalized suffix tree based on Ukkonen's algorithm
   combined with lossy counting.

   Assumes that individual strings have no duplicate characters,
   and that characters used at the end of strings are only ever
   used at the end of strings.
 *)

open Memtrace

module type Char = sig

  include Hashtbl.HashedType

  val dummy : t

end

module Substring_heavy_hitters (X : Char) : sig

  type t

  val create : error:float -> t

  val insert : t -> X.t array -> int -> unit

  val output : t -> frequency:float -> (X.t array * int * int * int) list * int

end = struct

  module Tbl = Hashtbl.Make(X)

  module Node : sig

    type t

    val is_root : t -> bool

    val create_root : unit -> t

    module Queue : sig

      type node = t

      type t

      val create : unit -> t

      (* Iterator that can safely squash the current leaf and add new leaves *)
      val iter : t -> (node -> unit) -> unit

    end

    val add_leaf :
      t -> queue:Queue.t -> array:X.t array -> index:int -> t

    val split_edge : parent:t -> child:t -> len:int -> t

    val set_suffix : t -> suffix:t -> unit

    val count : t -> int

    val delta : t -> int

    val add_count : t -> int -> unit

    val find_child : t -> X.t -> t option

    val get_child : t -> X.t -> t

    val edge_array : t -> X.t array

    val edge_start : t -> int

    val edge_length : t -> int

    val edge_key : t -> X.t

    val edge_char : t -> int -> X.t

    val has_suffix : t -> bool

    val suffix : t -> t

    val parent : t -> t

    val squash : queue:Queue.t -> t -> unit

    val reset_descendents_count : t -> unit

    val update_parents_descendents_counts : threshold:int -> t -> unit

    val iter_children : (t -> unit) -> t -> unit

    val fold_children : (t -> 'a -> 'a) -> t -> 'a -> 'a

    val is_heavy : threshold:int -> t -> bool

    val output : t -> X.t array * int * int * int

  end = struct

    type t =
      { mutable edge_array : X.t array;
        mutable edge_start : int;
        mutable edge_len : int;
        mutable edge_key : X.t;
        mutable parent : t;
        mutable suffix_link : t;
        mutable kind : kind;
        mutable count : int;
        mutable delta : int;
        mutable max_child_delta : int;
        mutable children : t Tbl.t;
        mutable incoming : int;
        mutable descendents_count : int;
        mutable heavy_descendents_count : int;
        mutable next : t;
        mutable previous: t; }

    and kind =
      | Dummy
      | Front_sentinal
      | Back_sentinal
      | Root
      | Branch
      | Leaf

    type queue =
      { front : t;
        back : t; }

    let same t1 t2 = t1 == t2

    let dummy_array = [||]

    let dummy_table = Tbl.create 0

    let dummy =
      let edge_array = dummy_array in
      let edge_start = 0 in
      let edge_len = 0 in
      let edge_key = X.dummy in
      let kind = Dummy in
      let count = 0 in
      let delta = 0 in
      let max_child_delta = 0 in
      let children = dummy_table in
      let incoming = 0 in
      let descendents_count = 0 in
      let heavy_descendents_count = 0 in
      let rec t =
        { edge_array; edge_start; edge_len; edge_key;
          parent = t; suffix_link = t; kind;
          count; delta; max_child_delta;
          children; incoming; descendents_count;
          heavy_descendents_count; next = t; previous = t; }
      in
      t

    let label t =
      let rec loop acc t =
        let edge = Array.sub t.edge_array t.edge_start t.edge_len in
        if not (same t t.parent) then loop (edge :: acc) t.parent
        else Array.concat (edge :: acc)
      in
      loop [] t

    let create_root () =
      let edge_array = dummy_array in
      let edge_start = 0 in
      let edge_len = 0 in
      let edge_key = X.dummy in
      let kind = Root in
      let count = 0 in
      let delta = 0 in
      let max_child_delta = 0 in
      let children = Tbl.create 37 in
      let incoming = 0 in
      let descendents_count = 0 in
      let heavy_descendents_count = 0 in
      let next = dummy in
      let previous = dummy in
      let rec node =
        { edge_array; edge_start; edge_len; edge_key;
          parent = node; suffix_link = node; kind;
          count; delta; max_child_delta;
          children; incoming; descendents_count;
          heavy_descendents_count; next; previous; }
      in
      node

    let set_next t ~next =
      match t.kind with
      | Dummy | Back_sentinal | Root | Branch ->
          assert false
      | Front_sentinal | Leaf -> t.next <- next

    let set_previous t ~previous =
      match t.kind with
      | Dummy | Front_sentinal | Root | Branch ->
          assert false
      | Back_sentinal | Leaf -> t.previous <- previous

    let convert_to_leaf ~queue t =
      let next = queue.back in
      let previous = queue.back.previous in
      t.kind <- Leaf;
      t.children <- dummy_table;
      t.next <- next;
      t.previous <- previous;
      set_previous next ~previous:t;
      set_next previous ~next:t

    let set_child ~parent ~key ~child =
      begin
        match parent.kind with
        | Dummy | Front_sentinal | Back_sentinal -> assert false
        | Leaf ->
            let next = parent.next in
            let previous = parent.previous in
            set_previous next ~previous;
            set_next previous ~next;
            parent.children <- Tbl.create 2;
            parent.kind <- Branch
        | Root | Branch -> ()
      end;
      Tbl.replace parent.children key child;
      parent.incoming <- parent.incoming + 1

    let remove_child ~queue ~parent ~child =
      let key = child.edge_key in
      Tbl.remove parent.children key;
      let incoming = parent.incoming - 1 in
      parent.incoming <- incoming;
      if incoming = 0 then begin
        match parent.kind with
        | Dummy | Front_sentinal | Back_sentinal | Leaf ->
            assert false
        | Root -> ()
        | Branch -> convert_to_leaf ~queue parent
      end

    let set_suffix t ~suffix =
      t.suffix_link <- suffix;
      suffix.incoming <- suffix.incoming + 1;
      match suffix.kind with
      | Dummy | Front_sentinal | Back_sentinal -> assert false
      | Root | Branch -> ()
      | Leaf ->
          let next = suffix.next in
          let previous = suffix.previous in
          set_previous next ~previous;
          set_next previous ~next;
          suffix.children <- Tbl.create 2;
          suffix.kind <- Branch

    let remove_incoming ~queue t =
      let incoming = t.incoming - 1 in
      t.incoming <- incoming;
      if incoming = 0 then begin
        match t.kind with
        | Dummy | Front_sentinal | Back_sentinal | Leaf ->
            assert false
        | Root -> ()
        | Branch -> convert_to_leaf ~queue t
      end

    let add_leaf t ~queue ~array ~index =
      let edge_array = array in
      let edge_start = index in
      let edge_len = (Array.length array) - index in
      let edge_key = array.(index) in
      let parent = t in
      let suffix_link = dummy in
      let kind = Leaf in
      let count = 0 in
      let max_child_delta = t.max_child_delta in
      let delta = max_child_delta in
      let children = dummy_table in
      let incoming = 0 in
      let descendents_count = 0 in
      let heavy_descendents_count = 0 in
      let next = queue.back in
      let previous = queue.back.previous in
      let node =
        { edge_array; edge_start; edge_len; edge_key;
          parent; suffix_link; kind;
          count; delta; max_child_delta;
          children; incoming; descendents_count;
          heavy_descendents_count; next; previous; }
      in
      set_previous next ~previous:node;
      set_next previous ~next:node;
      set_child ~parent:t ~key:edge_key ~child:node;
      node

    let split_edge ~parent ~child ~len =
      if (len = 0) then parent
      else begin
        let edge_array = child.edge_array in
        let edge_start = child.edge_start in
        let edge_key = child.edge_key in
        let child_key = edge_array.(edge_start + len) in
        let new_node =
          let edge_len = len in
          let suffix_link = dummy in
          let kind = Branch in
          let count = 0 in
          let delta = parent.max_child_delta in
          let max_child_delta = parent.max_child_delta in
          let children = Tbl.create 2 in
          Tbl.add children child_key child;
          let incoming = 1 in
          let descendents_count = 0 in
          let heavy_descendents_count = 0 in
          let next = dummy in
          let previous = dummy in
          { edge_array; edge_start; edge_len; edge_key;
            parent; suffix_link; kind;
            count; delta; max_child_delta;
            children; incoming; descendents_count;
            heavy_descendents_count; next; previous; }
        in
        child.edge_start <- edge_start + len;
        child.edge_len <- child.edge_len - len;
        child.edge_key <- child_key;
        child.parent <- new_node;
        set_child ~parent ~key:edge_key ~child:new_node;
        new_node
      end

    let is_root t =
      match t.kind with
      | Root -> true
      | _ -> false

    let count t = t.count

    let delta t = t.delta

    let add_count t count =
      t.count <- t.count + count

    let add_child_delta t delta =
      if delta > t.max_child_delta then begin
        t.max_child_delta <- delta
      end

    let find_child t char =
      match t.kind with
      | Dummy | Front_sentinal | Back_sentinal -> assert false
      | Leaf -> None
      | Root | Branch -> Tbl.find_opt t.children char

    let get_child t char =
      match Tbl.find t.children char with
      | child -> child
      | exception Not_found -> failwith "get_child: No such child"

    let edge_array t = t.edge_array

    let edge_start t = t.edge_start

    let edge_length t = t.edge_len

    let edge_key t = t.edge_key

    let edge_char t i =
      if i = 0 then t.edge_key
      else t.edge_array.(t.edge_start + i)

    let has_suffix t = not (same t.suffix_link dummy)

    let suffix t = t.suffix_link

    let parent t = t.parent

    let reset_descendents_count t =
      t.descendents_count <- 0

    let add_to_descendents_count t diff =
      t.descendents_count <- t.descendents_count + diff

    let add_to_heavy_descendents_count t diff =
      t.heavy_descendents_count <- t.heavy_descendents_count + diff

    let descendents_count t =
      t.descendents_count

    let heavy_descendents_count t =
      t.heavy_descendents_count

    let update_parents_descendents_counts ~threshold t =
      if is_root t then ()
      else begin
        let heavy_descendents_count = heavy_descendents_count t in
        let descendents_count = descendents_count t in
        let total = t.count + descendents_count in
        let light_total = total - heavy_descendents_count in
        let heavy_total =
          if light_total + t.delta > threshold then total
          else heavy_descendents_count
        in
        let parent = t.parent in
        let suffix = t.suffix_link in
        let grand_parent = t.parent.suffix_link in
        if not (same parent dummy) then begin
          add_to_descendents_count parent total;
          add_to_heavy_descendents_count parent heavy_total
        end;
        if not (same suffix dummy) then begin
          add_to_descendents_count suffix total;
          add_to_heavy_descendents_count suffix heavy_total
        end;
        if not (same grand_parent dummy) then begin
          add_to_descendents_count grand_parent (-total);
          add_to_heavy_descendents_count grand_parent (-heavy_total)
        end
      end

    let is_heavy ~threshold t =
      let heavy_descendents_count = heavy_descendents_count t in
      let descendents_count = descendents_count t in
      let total = t.count + descendents_count in
      let light_total = total - heavy_descendents_count in
      light_total + t.delta > threshold

    let output t =
      let heavy_descendents_count = heavy_descendents_count t in
      let descendents_count = descendents_count t in
      let total = t.count + descendents_count in
      let light_total = total - heavy_descendents_count in
      (label t, light_total, total, total + t.delta)

    let iter_children f t =
      match t.kind with
      | Dummy | Front_sentinal | Back_sentinal -> assert false
      | Leaf -> ()
      | Root | Branch -> Tbl.iter (fun _ n -> f n) t.children

    let fold_children f t acc =
      match t.kind with
      | Dummy | Front_sentinal | Back_sentinal -> assert false
      | Leaf -> acc
      | Root | Branch -> Tbl.fold (fun _ n -> f n) t.children acc

    let squash ~queue t =
      match t.kind with
      | Dummy | Front_sentinal | Back_sentinal -> assert false
      | Root | Branch -> failwith "squash: Not a leaf"
      | Leaf ->
          let next = t.next in
          let previous = t.previous in
          set_previous next ~previous;
          set_next previous ~next;
          t.kind <- Dummy;
          t.next <- dummy;
          t.previous <- dummy;
          let parent = t.parent in
          let suffix = t.suffix_link in
          let count = t.count in
          if not (same parent dummy) then begin
            let grand_parent = t.parent.suffix_link in
            add_count parent count;
            add_child_delta parent (count + t.delta);
            remove_child ~queue ~parent ~child:t;
            if not (same grand_parent dummy) then begin
              add_count grand_parent (-count)
            end
          end;
          if not (same suffix dummy) then begin
            add_count suffix count;
            remove_incoming ~queue suffix
          end;

    module Queue = struct

      type node = t

      type t = queue

      let create () =
        let edge_array = dummy_array in
        let edge_start = 0 in
        let edge_len = 0 in
        let edge_key = X.dummy in
        let count = 0 in
        let delta = 0 in
        let max_child_delta = 0 in
        let parent = dummy in
        let suffix_link = dummy in
        let children = dummy_table in
        let incoming = 0 in
        let descendents_count = 0 in
        let heavy_descendents_count = 0 in
        let front =
          let kind = Front_sentinal in
          let next = dummy in
          let previous = dummy in
          { edge_array; edge_start; edge_len; edge_key;
            parent; suffix_link; kind;
            count; delta; max_child_delta;
            children; incoming; descendents_count;
            heavy_descendents_count; next; previous; }
        in
        let back =
          let kind = Back_sentinal in
          let next = dummy in
          let previous = front in
          { edge_array; edge_start; edge_len; edge_key;
            parent; suffix_link; kind;
            count; delta; max_child_delta;
            children; incoming; descendents_count;
            heavy_descendents_count; next; previous; }
        in
        set_next front ~next:back;
        { front; back }

      let is_back_sentinal t =
        match t.kind with
        | Back_sentinal -> true
        | _ -> false

      let iter t f =
        let previous = ref t.front in
        let current = ref (t.front.next) in
        while not (is_back_sentinal !current) do
          f !current;
          let next_current = !current.next in
          if same next_current dummy then begin
            current := !previous.next
          end else begin
            previous := !current;
            current := next_current
          end
        done

    end

  end

  module Cursor : sig

    type t

    val create : at:Node.t -> t

    val scan : t -> array:X.t array -> index:int -> bool

    val split_at : t -> Node.t

    val goto_suffix : t -> Node.t -> unit

  end = struct

    type t =
      { mutable parent : Node.t;
        mutable len : int;
        mutable child : Node.t; } (* = parent if len is 0 *)

    let create ~at =
      { parent = at;
        len = 0;
        child = at; }

    let goto t node =
      t.parent <- node;
      t.len <- 0;
      t.child <- node

    (* Move cursor 1 character towards child. Child assumed
       not equal to parent. *)
    let extend t =
      let len = t.len + 1 in
      if (Node.edge_length t.child) <= len then begin
        t.parent <- t.child;
        t.len <- 0
      end else begin
        t.len <- len
      end

    (* Try to move cursor n character towards child. Child assumed
       not equal to parent. Returns number of characters actually moved.
       Guaranteed to move at least 1 character. *)
    let extend_n t n =
      let len = t.len in
      let target = len + n in
      let edge_len = Node.edge_length t.child in
      if edge_len <= target then begin
        t.parent <- t.child;
        t.len <- 0;
        edge_len - len
      end else begin
        t.len <- target;
        n
      end

    let scan t ~array ~index =
      let char = array.(index) in
      let len = t.len in
      if len = 0 then begin
        match Node.find_child t.parent char with
        | None -> false
        | Some child ->
            t.child <- child;
            extend t;
            true
      end else begin
        let next_char = Node.edge_char t.child len in
        if X.equal char next_char then begin
          extend t;
          true
        end else begin
          false
        end
      end

    let split_at t =
      let len = t.len in
      if len = 0 then t.parent
      else begin
        let node = Node.split_edge ~parent:t.parent ~child:t.child ~len in
        goto t node;
        node
      end

    let rec rescan t ~array ~start ~len =
      if len = 0 then ()
      else begin
        if t.len = 0 then begin
          let char = array.(start) in
          let child = Node.get_child t.parent char in
          t.child <- child
        end;
        let diff = extend_n t len in
        let start = start + diff in
        let len = len - diff in
        rescan t ~array ~start ~len
      end

    let rescan1 t ~key =
      if t.len = 0 then begin
        let child = Node.get_child t.parent key in
        t.child <- child
      end;
      extend t

    let rec goto_suffix t node =
      if Node.is_root node then begin
        goto t node
      end else if Node.has_suffix node then begin
        goto t (Node.suffix node)
      end else begin
        let parent = Node.parent node in
        let len = Node.edge_length node in
        if len = 1 then begin
          if Node.is_root parent then begin
            goto t parent
          end else begin
            let key = Node.edge_key node in
            goto_suffix t parent;
            rescan1 t ~key
          end
        end else begin
          let array = Node.edge_array node in
          let start = Node.edge_start node in
          if Node.is_root parent then begin
            goto t parent;
            let start = start + 1 in
            let len = len - 1 in
            rescan t ~array ~start ~len
          end else begin
            goto_suffix t parent;
            rescan t ~array ~start ~len
          end
        end
      end

  end

  type t =
    { root : Node.t;
      leaves : Node.Queue.t;
      mutable max_length : int;
      mutable count : int;
      bucket_size : int;
      mutable current_bucket : int;
      mutable remaining_in_current_bucket : int;
    }

  let create ~error =
    let root = Node.create_root () in
    let leaves = Node.Queue.create () in
    let max_length = 0 in
    let count = 0 in
    let bucket_size = Float.to_int (Float.ceil (1.0 /. error)) in
    let current_bucket = 0 in
    let remaining_in_current_bucket = bucket_size in
    { root; leaves; max_length; count;
      bucket_size; current_bucket; remaining_in_current_bucket; }

  let ensure_suffixes cursor node =
    let current = ref node in
    while not (Node.has_suffix !current) do
      Cursor.goto_suffix cursor !current;
      let suffix = Cursor.split_at cursor in
      Node.set_suffix !current ~suffix;
      current := suffix
    done

  let compress t =
    let queue = t.leaves in
    Node.Queue.iter queue
      (fun leaf ->
         let upper_bound = Node.count leaf + Node.delta leaf in
         if upper_bound < t.current_bucket then Node.squash ~queue leaf)

  let insert t array count =
    let len = Array.length array in
    if len > t.max_length then t.max_length <- len;
    t.count <- t.count + count;
    let queue = t.leaves in
    let active = Cursor.create ~at:t.root in
    let j = ref 0 in
    let destination = ref None in
    for index = 0 to len - 1 do
      while (!j <= index) && not (Cursor.scan active ~array ~index) do
        let parent = Cursor.split_at active in
        let leaf = Node.add_leaf parent ~queue ~array ~index in
        begin
          match !destination with
          | None -> destination := Some leaf
          | Some _ -> ()
        end;
        Cursor.goto_suffix active parent;
        if not (Node.has_suffix parent) then begin
          let suffix = Cursor.split_at active in
          Node.set_suffix parent ~suffix
        end;
        incr j
      done
    done;
    let destination =
      match !destination with
      | Some destination -> destination
      | None -> Cursor.split_at active
    in
    Node.add_count destination count;
    ensure_suffixes active destination;
    let remaining = t.remaining_in_current_bucket - 1 in
    if remaining <= 0 then begin
      t.current_bucket <- t.current_bucket + 1;
      t.remaining_in_current_bucket <- t.bucket_size;
      compress t
    end else begin
      t.remaining_in_current_bucket <- remaining
    end

  let update_descendent_counts ~threshold t =
    let nodes : Node.t list array = Array.make (t.max_length + 1) [] in
    let rec loop depth node =
      Node.reset_descendents_count node;
      let depth = depth + Node.edge_length node in
      nodes.(depth) <- node :: nodes.(depth);
      Node.iter_children (loop depth) node
    in
    loop 0 t.root;
    for i = t.max_length downto 0 do
      List.iter (Node.update_parents_descendents_counts ~threshold) nodes.(i)
    done

  let output t ~frequency =
    let threshold =
        Float.to_int (Float.floor (frequency *. (Float.of_int t.count)))
    in
    let cmp (_, (light_count1 : int), _, _) (_, (light_count2 : int), _, _) =
      compare light_count2 light_count1
    in
    update_descendent_counts ~threshold t;
    let rec loop node acc =
      let acc = Node.fold_children loop node acc in
      if Node.is_heavy ~threshold node then
        List.merge cmp [Node.output node] acc
      else
        acc
    in
    Node.fold_children loop t.root [], t.count

end


module Location = struct

  type t = location_code

  let hash (x : t) =
    Int64.(shift_right (mul (x :> int64) 984372984721L) 17 |> to_int)

  let equal (x : t) (y : t) =
    Int64.equal (x :> int64) (y :> int64)

  let dummy = (Obj.magic (-1L : int64) : t)

end

module Loc_hitters = Substring_heavy_hitters(Location)

module Loc_tbl = Hashtbl.Make(Location)

let error = 0.001

let wordsize = 8.  (* FIXME: store this in the trace *)

let print_bytes ppf = function
  | n when n < 100. ->
    Format.fprintf ppf "%4.0f B" n
  | n when n < 100. *. 1024. ->
    Format.fprintf ppf "%4.1f kB" (n /. 1024.)
  | n when n < 100. *. 1024. *. 1024. ->
    Format.fprintf ppf "%4.1f MB" (n /. 1024. /. 1024.)
  | n when n < 100. *. 1024. *. 1024. *. 1024. ->
    Format.fprintf ppf "%4.1f GB" (n /. 1024. /. 1024. /. 1024.)
  | n ->
    Format.fprintf ppf "%4.1f TB" (n /. 1024. /. 1024. /. 1024. /. 1024.)

let print_location ppf {filename; line; start_char; end_char; defname} =
  Format.fprintf ppf
    "%s (%s:%d:%d-%d)" defname filename line start_char end_char

let print_locations ppf locations =
  Format.pp_print_list ~pp_sep:Format.pp_print_space print_location
    ppf locations

let print_loc_code trace ppf loc =
  print_locations ppf (List.rev (Memtrace.lookup_location trace loc))

let print_loc_codes trace ppf locs =
  for i = (Array.length locs) - 1 downto 0 do
    Format.pp_print_space ppf ();
    print_loc_code trace ppf locs.(i)
  done

let print_hitter trace tinfo total ppf (locs, light_count, count, _) =
  let freq = float_of_int count /. float_of_int total in
  let light_bytes = float_of_int light_count /. tinfo.sample_rate *. wordsize in
  let bytes = float_of_int count /. tinfo.sample_rate *. wordsize in
  Format.fprintf ppf "@[<v 4>%a/%a (%4.1f%%) under%a@]"
    print_bytes light_bytes print_bytes bytes (100. *. freq)
    (print_loc_codes trace) locs

let print_hitters trace tinfo total ppf hitters =
  let pp_sep ppf () =
    Format.pp_print_space ppf ();
    Format.pp_print_space ppf ()
  in
  Format.pp_print_list ~pp_sep
    (print_hitter trace tinfo total) ppf hitters

let print_report trace ppf (hitters, total) =
  let tinfo = trace_info trace in
  Format.fprintf ppf
    "@[<v 2>@ Trace for %s [%ld]:@ %d samples of %a allocations@ \
     @[<v 2>@ %a@ @]@ "
    tinfo.executable_name tinfo.pid
    total
    print_bytes (float_of_int total /. tinfo.sample_rate *. wordsize)
    (print_hitters trace tinfo total) hitters

let count ~frequency ~filename =
  let trace = open_trace ~filename in
  let shh = Loc_hitters.create ~error in
  let seen = Loc_tbl.create 100 in
  iter_trace trace
    (fun _time ev ->
       match ev with
       | Alloc {obj_id=_; length=_; nsamples; is_major=_;
                backtrace_buffer; backtrace_length; common_prefix=_} ->
           let rev_trace = ref [] in
           Loc_tbl.clear seen;
           for i = backtrace_length - 1 downto 0 do
             let loc = backtrace_buffer.(i) in
             if not (Loc_tbl.mem seen loc) then begin
               rev_trace := loc :: !rev_trace;
               Loc_tbl.add seen loc ()
             end
           done;
           Loc_hitters.insert shh (Array.of_list !rev_trace) nsamples
      | Promote _ -> ()
      | Collect _ -> ());
  let results = Loc_hitters.output shh ~frequency in
  Format.printf "%a" (print_report trace) results;
  close_trace trace

let default_frequency = 0.01

let () =
  if Array.length Sys.argv = 2 then begin
    count ~frequency:default_frequency ~filename:Sys.argv.(1)
  end else if Array.length Sys.argv = 3 then begin
    match Float.of_string Sys.argv.(2) with
    | frequency -> count ~frequency ~filename:Sys.argv.(1)
    | exception Failure _ ->
        Printf.fprintf stderr "Usage: %s <trace file> [frequency]\n"
          Sys.executable_name
  end else begin
    Printf.fprintf stderr "Usage: %s <trace file> [frequency]\n"
      Sys.executable_name
  end
