(* Buffer management *)

type buffer = {
  buf : Bytes.t;
  pos_end : int;
  mutable pos : int;
}

let remaining b =
  b.pos_end - b.pos

let mkbuffer buf off len =
  if len < 0 then
    raise (Invalid_argument "mkbuffer: negative length");
  if off + len > Bytes.length buf then
    raise (Invalid_argument "mkbuffer: out of bounds");
  { buf; pos = off; pos_end = off + len }

let mkbuffer buf =
  mkbuffer buf 0 (Bytes.length buf)

external put_raw_16 : Bytes.t -> int -> int -> unit = "%caml_bytes_set16u"
external put_raw_32 : Bytes.t -> int -> int32 -> unit = "%caml_bytes_set32u"
external put_raw_64 : Bytes.t -> int -> int64 -> unit = "%caml_bytes_set64u"
external get_raw_16 : Bytes.t -> int -> int = "%caml_bytes_get16"
external get_raw_32 : Bytes.t -> int -> int32 = "%caml_bytes_get32"
external get_raw_64 : Bytes.t -> int -> int64 = "%caml_bytes_get64"
external bswap_16 : int -> int = "%bswap16"
external bswap_32 : int32 -> int32 = "%bswap_int32"
external bswap_64 : int64 -> int64 = "%bswap_int64"

exception Gen_error of [`Overflow of int]
exception Parse_error of [`Underflow of int | `Bad_format of string]

let[@inline never] overflow b = raise (Gen_error (`Overflow b.pos))
let[@inline never] underflow b = raise (Parse_error (`Underflow b.pos))
let[@inline never] bad_format s = raise (Parse_error (`Bad_format s))
let check_fmt s b = if not b then bad_format s


let put_8 b v =
  let pos = b.pos in
  let pos' = b.pos + 1 in
  if pos' > b.pos_end then overflow b else
  (Bytes.unsafe_set b.buf pos (Char.unsafe_chr v);
   b.pos <- pos')
let put_16 b v =
  let pos = b.pos in
  let pos' = b.pos + 2 in
  if pos' > b.pos_end then overflow b else
  (put_raw_16 b.buf pos (if Sys.big_endian then bswap_16 v else v);
   b.pos <- pos')
let put_32 b v =
  let pos = b.pos in
  let pos' = b.pos + 4 in
  if pos' > b.pos_end then overflow b else
  (put_raw_32 b.buf pos (if Sys.big_endian then bswap_32 v else v);
   b.pos <- pos')
let put_64 b v =
  let pos = b.pos in
  let pos' = b.pos + 8 in
  if pos' > b.pos_end then overflow b else
  (put_raw_64 b.buf pos (if Sys.big_endian then bswap_64 v else v);
   b.pos <- pos')
let[@inline never] put_vint_big b v =
  if v = v land 0xffff then
    (put_8 b 253; put_16 b v)
  else if v = v land 0xffffffff then
    (put_8 b 254; put_32 b (Int32.of_int v))
  else
    (put_8 b 255; put_64 b (Int64.of_int v))
let put_vint b v =
  if 0 <= v && v <= 252 then
    put_8 b v
  else
    put_vint_big b v
let put_string b s =
  let slen = String.length s in
  if b.pos + slen + 1 > b.pos_end then overflow b;
  Bytes.blit_string s 0 b.buf b.pos slen;
  Bytes.unsafe_set b.buf (b.pos + slen) '\000';
  b.pos <- b.pos + slen + 1

let get_8 b =
  if b.pos + 1 > b.pos_end then underflow b;
  let n = Bytes.unsafe_get b.buf b.pos in
  b.pos <- b.pos + 1;
  Char.code n
let get_16 b =
  if b.pos + 2 > b.pos_end then underflow b;
  let n = get_raw_16 b.buf b.pos in
  b.pos <- b.pos + 2;
  if Sys.big_endian then bswap_16 n else n
let get_32 b =
  if b.pos + 4 > b.pos_end then underflow b;
  let n = get_raw_32 b.buf b.pos in
  b.pos <- b.pos + 4;
  if Sys.big_endian then bswap_32 n else n
let get_64 b =
  if b.pos + 8 > b.pos_end then underflow b;
  let n = get_raw_64 b.buf b.pos in
  b.pos <- b.pos + 8;
  if Sys.big_endian then bswap_64 n else n
(* FIXME: overflow if deserialised on 32-bit. Should I care? *)
let get_vint b =
  match get_8 b with
  | 253 -> get_16 b
  | 254 -> get_32 b |> Int32.to_int
  | 255 -> get_64 b |> Int64.to_int
  | n -> n
let get_string b =
  let start = b.pos in
  while get_8 b <> 0 do () done;
  let len = b.pos - 1 - start in
  Bytes.sub_string b.buf start len



type times = { mutable t_start : float; mutable t_end : float }

let cache_size = 1 lsl 15
type cache_bucket = int  (* 0 to cache_size - 1 *)

type memtrace_reader_cache = {
  cache_loc : int array;
  cache_pred : int array;
}

let create_reader_cache () =
  { cache_loc = Array.make cache_size 0;
    cache_pred = Array.make cache_size 0 }

type mtf_table = string array
type memtrace_writer = {
  dest : Unix.file_descr;
  file_mtf : mtf_table;
  mutable new_locs : (int * Printexc.raw_backtrace_slot) array;
  mutable new_locs_len : int;
  new_locs_buf : Bytes.t;
  mutable last_callstack : int array;

  cache : int array;
  (* when an entry was added to the cache (used for eviction) *)
  cache_date : int array;
  (* last time we saw this entry, which entry followed it? *)
  cache_next : cache_bucket array;

  (* for debugging *)
  debug_cache : memtrace_reader_cache option;

  mutable start_alloc_id : int; (* alloc ID at start of packet *)
  mutable next_alloc_id : int;
  mutable packet_times : times;
  mutable packet : buffer;
}

type location = {
  filename : string;
  line : int;
  start_char : int;
  end_char : int;
}

let log_new_loc s loc =
  let alen = Array.length s.new_locs in
  assert (s.new_locs_len <= alen);
  if s.new_locs_len = alen then begin
    let new_len = if alen = 0 then 32 else alen * 2 in
    let locs = Array.make new_len loc in
    Array.blit s.new_locs 0 locs 0 alen;
    s.new_locs <- locs;
    s.new_locs_len <- alen + 1
  end else begin
    s.new_locs.(s.new_locs_len) <- loc;
    s.new_locs_len <- s.new_locs_len + 1
  end

let to_timestamp_64 t =
  t *. 1_000_000. |> Float.to_int |> Int64.of_int
let of_timestamp_64 n =
  Float.of_int (Int64.to_int n) /. 1_000_000.
let put_timestamp b t =
  put_64 b (to_timestamp_64 t)
let get_timestamp b =
  of_timestamp_64 (get_64 b)


let put_ctf_header b size tstart tend alloc_id_begin alloc_id_end =
  put_32 b 0xc1fc1fc1l;
  (* CTF sizes are in bits *)
  put_32 b (Int32.mul (Int32.of_int size) 8l);
  put_32 b (Int32.mul (Int32.of_int size) 8l);
  put_timestamp b tstart;
  put_timestamp b tend;
  put_64 b (Int64.of_int alloc_id_begin);
  put_64 b (Int64.of_int alloc_id_end)

type header_info = {
  content_size: int; (* bytes, excluding header *)
  time_begin : Int64.t;
  time_end : Int64.t;
  alloc_id_begin : Int64.t;
  alloc_id_end : Int64.t;
}
let get_ctf_header b =
  let start = b.pos in
  let magic = get_32 b in
  let packet_size = get_32 b in
  let content_size = get_32 b in
  let time_begin = get_64 b in
  let time_end = get_64 b in
  let alloc_id_begin = get_64 b in
  let alloc_id_end = get_64 b in
  check_fmt "Not a CTF packet" (magic = 0xc1fc1fc1l);
  check_fmt "Bad packet size" (packet_size >= 0l);
  check_fmt "Bad content size" (content_size = packet_size);
  check_fmt "Monotone packet timestamps" (time_begin <= time_end);
  check_fmt "Monotone alloc IDs" (alloc_id_begin <= alloc_id_end);
  let header_size = b.pos - start in
  {
    content_size = Int32.(to_int (div packet_size 8l) - header_size);
    time_begin;
    time_end;
    alloc_id_begin;
    alloc_id_end
  }



type evcode = Ev_location | Ev_alloc | Ev_promote | Ev_collect
let event_code = function
  | Ev_location -> 0
  | Ev_alloc -> 1
  | Ev_promote -> 2
  | Ev_collect -> 3
let event_of_code = function
  | 0 -> Ev_location
  | 1 -> Ev_alloc
  | 2 -> Ev_promote
  | 3 -> Ev_collect
  | c -> bad_format ("Unknown event code " ^ string_of_int c)

let event_header_time_len = 25
let event_header_time_mask = 0x1ffffffl
let put_event_header b ev t =
  let t = to_timestamp_64 t in
  let code =
    Int32.(logor (shift_left (of_int (event_code ev))
                    event_header_time_len)
             (logand (Int64.to_int32 t) event_header_time_mask)) in
  put_32 b code
let get_event_header info b =
  let code = get_32 b in
  let start_low = Int32.logand event_header_time_mask (Int64.to_int32 info.time_begin) in
  let time_low = Int32.logand event_header_time_mask code in
  let time_low =
    if time_low < start_low then
      (* Overflow *)
      Int32.(add time_low (of_int (1 lsl event_header_time_len)))
    else
      time_low in
  let time =
    Int64.(add (logand info.time_begin (lognot (of_int32 event_header_time_mask)))
             (of_int32 time_low)) in
  check_fmt "time in packet bounds" (info.time_begin <= time);
  check_fmt "time in packet bounds" (time <= info.time_end);
  let ev = event_of_code (Int32.(to_int (shift_right code
                                           event_header_time_len))) in
  (ev, of_timestamp_64 time)

let mtf_length = 15
let create_mtf_table () =
  Array.init mtf_length (fun i -> "??"^string_of_int i) (* must be distinct *)
let mtf_encode mtf filename =
  let rec insert mtf prev filename i =
    if i = mtf_length then
      (* not found *)
      i
    else begin
      let curr = mtf.(i) in
      mtf.(i) <- prev;
      if String.equal curr filename then
        i
      else
        insert mtf curr filename (i+1)
    end in
  if String.equal mtf.(0) filename then
    0
  else
    let prev = mtf.(0) in
    mtf.(0) <- filename;
    insert mtf prev filename 1
let mtf_decode mtf i =
  assert (i < mtf_length);
  if i = 0 then
    mtf.(0)
  else begin
    let f = mtf.(i) in
    Array.blit mtf 0 mtf 1 i;
    mtf.(0) <- f;
    f
  end
let mtf_new mtf filename =
  Array.blit mtf 0 mtf 1 (mtf_length - 1);
  mtf.(0) <- filename

(* FIXME: max_location overflow *)
let max_location = 4 * 1024
let put_backtrace_slot b file_mtf (id, loc) =
  let open Printexc in
  let rec get_locations slot =
    let tail =
      match get_raw_backtrace_next_slot slot with
      | None -> []
      | Some slot -> get_locations slot in
    let slot = convert_raw_backtrace_slot slot in
    match Slot.location slot with
    | None -> tail
    | Some l -> l :: tail in
  let locs = get_locations loc |> List.rev in
  let max_locs = 255 in
  let locs =
    if List.length locs <= max_locs then locs else
      ((List.filteri (fun i _ -> i < max_locs - 1) locs)
       @
      [ { filename = "<unknown>"; line_number = 1; start_char = 1; end_char = 1 } ]) in
  assert (List.length locs <= max_locs);
  put_64 b (Int64.of_int id);
  put_8 b (List.length locs);
  locs |> List.iter (fun (loc : location) ->
    let clamp n lim = if n < 0 || n > lim then lim else n in
    let line_number = clamp loc.line_number 0xfffff in
    let start_char = clamp loc.start_char 0xfff in
    let end_char = clamp loc.end_char 0xfff in
    let filename_code = mtf_encode file_mtf loc.filename in
    put_32 b (Int32.(logor (of_int line_number) (shift_left (of_int start_char) 20)));
    put_16 b (end_char lor (filename_code lsl 12));
    if filename_code = mtf_length then
      put_string b loc.filename)

let get_backtrace_slot file_mtf b =
  let id = Int64.to_int (get_64 b) in
  let nlocs = get_8 b in
  let locs = List.init nlocs (fun _ ->
    let line, start_char =
      let n = get_32 b in
      Int32.(to_int (logand n 0xfffffl), to_int (shift_right n 20)) in
    let end_char, filename_code =
      let n = get_16 b in
      n land 0xfff, n lsr 12 in
    let filename =
      match filename_code with
      | n when n = mtf_length ->
        let s = get_string b in
        mtf_new file_mtf s;
        s
      | n -> mtf_decode file_mtf n in
    { line; start_char; end_char; filename }) in
  (id, locs)

let flush s =
  (* First, flush newly-seen locations.
     These must be emitted before any events that might refer to them *)
  let i = ref 0 in
  while !i < s.new_locs_len do
    let b = mkbuffer s.new_locs_buf in
    put_ctf_header b 0 0. 0. 0 0;
    while !i < s.new_locs_len && remaining b > max_location do
      put_event_header b Ev_location s.packet_times.t_start;
      put_backtrace_slot b s.file_mtf s.new_locs.(!i);
      incr i
    done;
    let blen = b.pos in
    put_ctf_header
      (mkbuffer s.new_locs_buf)
      blen
      s.packet_times.t_start
      s.packet_times.t_start
      s.start_alloc_id
      s.start_alloc_id;
    Unix.write s.dest s.new_locs_buf 0 blen |> ignore
  done;
  (* Next, flush the actual events *)
  let evlen = s.packet.pos in
  put_ctf_header
    (mkbuffer s.packet.buf)
    evlen
    s.packet_times.t_start
    s.packet_times.t_end
    s.start_alloc_id
    s.next_alloc_id;
  Unix.write s.dest s.packet.buf 0 evlen |> ignore;
  (* Finally, reset the buffer *)
  s.packet_times.t_start <- s.packet_times.t_end;
  s.new_locs_len <- 0;
  s.packet <- mkbuffer s.packet.buf;
  s.start_alloc_id <- s.next_alloc_id;
  put_ctf_header s.packet 0 0. 0. 0 0

let max_ev_size = 4096  (* FIXME arbitrary number, overflow *)

let begin_event s ev =
  if remaining s.packet < max_ev_size || s.new_locs_len > 128 then flush s;
  let now = Unix.gettimeofday () in
  s.packet_times.t_end <- now;
  put_event_header s.packet ev now


let get_coded_backtrace { cache_loc ; cache_pred } b =
  let rec decode pred acc = function
    | 0 -> List.rev acc
    | i ->
      let codeword = get_16 b in
      let bucket = codeword lsr 1 and tag = codeword land 1 in
      cache_pred.(pred) <- bucket;
      if tag = 0 then begin
        (* cache hit *)
        let ncorrect = get_8 b in
        predict bucket (cache_loc.(bucket) :: acc) (i - 1) ncorrect
      end else begin
        (* cache miss *)
        let lit = Int64.to_int (get_64 b) in
        cache_loc.(bucket) <- lit;
        decode bucket (lit :: acc) (i - 1)
      end
  and predict pred acc i = function
    | 0 -> decode pred acc i
    | n ->
      let pred' = cache_pred.(pred) in
      predict pred' (cache_loc.(pred') :: acc) i (n-1) in
  let n = get_16 b in
  decode 0 [] n

let log_alloc s is_major (info : Gc.Memprof.allocation) =
  begin_event s Ev_alloc;
  let id = s.next_alloc_id in
  s.next_alloc_id <- id + 1;

  (* Find length of common suffix *)
  let raw_stack : int array = Obj.magic info.callstack in
  let last = s.last_callstack in
  let suff = ref 0 in
  let i = ref (Array.length raw_stack - 1)
  and j = ref (Array.length last - 1) in
  while !i >= 0 && !j >= 0 do
    if Array.unsafe_get raw_stack !i = Array.unsafe_get last !j then begin
      incr suff;
      decr i;
      decr j
    end else begin
      j := -1
    end
  done;
  s.last_callstack <- raw_stack;

  let b = s.packet in
  let common_pfx_len = Array.length raw_stack - 1 - !i in
  put_vint b info.size;
  put_vint b info.n_samples;
  put_8 b (if is_major then 1 else 0);
  put_vint b common_pfx_len;

  let bt_off = b.pos in
  put_16 b 0;

  Printf.printf "!\n%!";

  let rec code_no_prediction predictor pos ncodes =
    if pos < 0 then
      ncodes
    else begin
      let mask = cache_size - 1 in
      let slot = raw_stack.(pos) in
      let hash1 = ((slot * 0x4983723) lsr 11) land mask in
      let hash2 = ((slot * 0xfdea731) lsr 21) land mask in
      if s.cache.(hash1) = slot then begin
        code_cache_hit predictor hash1 pos ncodes
      end else if s.cache.(hash2) = slot then begin
        code_cache_hit predictor hash2 pos ncodes
      end else begin
        (* cache miss *)
        log_new_loc s (slot, Printexc.get_raw_backtrace_slot info.callstack pos);
        let bucket =
          if s.cache_date.(hash1) < s.cache_date.(hash2) then hash1 else hash2 in
        Printf.printf "miss %05d %016x\n%!" bucket slot; (*" %016x\n%!" bucket slot;*)
        s.cache.(bucket) <- slot;
        s.cache_date.(bucket) <- id;
        s.cache_next.(predictor) <- bucket;
        put_16 s.packet ((bucket lsl 1) lor 1);
        put_64 s.packet (Int64.of_int slot);
        code_no_prediction bucket (pos-1) (ncodes + 1)
      end
    end
  and code_cache_hit predictor hit pos ncodes =
    Printf.printf "hit %d\n" hit;
    s.cache_date.(hit) <- id;
    put_16 s.packet (hit lsl 1);
    s.cache_next.(predictor) <- hit;
    code_with_prediction hit 0 (pos-1) (ncodes+1)
  and code_with_prediction predictor ncorrect pos ncodes =
    assert (ncorrect < 256);
    if pos < 0 then begin
      put_8 s.packet ncorrect;
      ncodes
    end else begin
      let slot = raw_stack.(pos) in
      let pred_bucket = s.cache_next.(predictor) in
      if s.cache.(pred_bucket) = slot then begin
        (* correct prediction *)
        Printf.printf "pred %d %d\n" pred_bucket ncorrect;
        if ncorrect = 255 then begin
          (* overflow: code a new prediction block *)
          put_8 s.packet ncorrect;
          code_cache_hit predictor pred_bucket pos ncodes
        end else begin
          code_with_prediction pred_bucket (ncorrect + 1) (pos-1) ncodes
        end
      end else begin
        (* incorrect prediction *)
        put_8 s.packet ncorrect;
        code_no_prediction predictor pos ncodes
      end
    end in
  let ncodes = code_no_prediction 0 !i 0 in
  (* FIXME: bound this properly *)
  assert (ncodes <= 0xffff);
  put_raw_16 b.buf bt_off ncodes;

  (match s.debug_cache with
   | None -> ()
   | Some c ->
     let b' = { buf = b.buf; pos = bt_off; pos_end = b.pos } in
     let decoded_suff = get_coded_backtrace c b' in
     assert (remaining b' = 0);
     let common_pref =
       Array.sub last (Array.length last - common_pfx_len) common_pfx_len |> Array.to_list |> List.rev in
     let decoded = common_pref @ decoded_suff in
     if decoded <> (raw_stack |> Array.to_list |> List.rev) then begin
     last |> Array.to_list |> List.rev |> List.iter (Printf.printf " %08x"); Printf.printf "\n";
     raw_stack |> Array.to_list |> List.rev |> List.iter (Printf.printf " %08x"); Printf.printf "\n";
     decoded |> List.iter (Printf.printf " %08x"); Printf.printf " !\n";
     List.init common_pfx_len (fun _ -> ".") |> List.iter (Printf.printf " %8s");
        decoded_suff |> List.iter (Printf.printf " %08x"); Printf.printf "\n%!";
     failwith "bad coded backtrace"
     end);

  Some id

type obj_id = int
type loc_id = int

type event =
  | Alloc of {
    obj_id : obj_id;
    length : int;
    nsamples : int;
    is_major : bool;
    common_prefix : int;
    new_suffix : loc_id list;
  }
  | Promote of obj_id
  | Collect of obj_id

let get_alloc cache alloc_id b =
  let length = get_vint b in
  let nsamples = get_vint b in
  let is_major = get_8 b |> function 0 -> false | _ -> true in
  let common_prefix = get_vint b in
  let new_suffix = get_coded_backtrace cache b in
  Alloc { obj_id = alloc_id; length; nsamples; is_major; common_prefix; new_suffix }

(* FIXME: overflow, failure to bump end time *)

let log_promote s id =
  begin_event s Ev_promote;
  assert (id < s.next_alloc_id);
  let b = s.packet in
  put_vint b (s.next_alloc_id - 1 - id);
  Some id
let get_promote alloc_id b =
  let id_delta = get_vint b in
  check_fmt "promote id sync" (id_delta >= 0);
  let id = alloc_id - 1 - id_delta in
  Promote id

let log_collect s id =
  begin_event s Ev_collect;
  assert (id < s.next_alloc_id);
  let b = s.packet in
  put_vint b (s.next_alloc_id - 1 - id)
let get_collect alloc_id b =
  let id_delta = get_vint b in
  check_fmt "collect id sync" (id_delta >= 0);
  let id = alloc_id - 1 - id_delta in
  Collect id

let start_memprof dest sampling_rate =
  let now = Unix.gettimeofday () in
  let s = {
    dest;
    file_mtf = create_mtf_table ();
    new_locs = [| |];
    new_locs_len = 0;
    (* FIXME magic size *)
    new_locs_buf = Bytes.make 8000 '\102';

    cache = Array.make cache_size 0;
    cache_date = Array.make cache_size 0;
    cache_next = Array.make cache_size 0;
    debug_cache = Some (create_reader_cache ());

    last_callstack = [| |];
    next_alloc_id = 0;
    start_alloc_id = 0;
    packet_times = { t_start = now; t_end = now };
    packet = mkbuffer (Bytes.make 8000 '\102');
  } in
  put_ctf_header s.packet 0 0. 0. 0 0;
  Gc.Memprof.start
    ~callstack_size:max_int
    ~minor_alloc_callback:(fun info -> log_alloc s false info)
    ~major_alloc_callback:(fun info -> log_alloc s true info)
    ~promote_callback:(fun id -> log_promote s id)
    ~minor_dealloc_callback:(fun id -> log_collect s id)
    ~major_dealloc_callback:(fun id -> log_collect s id)
    ~sampling_rate
    ();
  s

let stop_memprof s =
  Gc.Memprof.stop ();
  flush s

let parse_packet_events file_mtf loc_table cache hdrinfo b f =
  let alloc_id = ref (Int64.to_int hdrinfo.alloc_id_begin) in
  let last_time = ref 0. in
  while remaining b > 0 do
    let last_pos = b.pos in
    let (ev, time) = get_event_header hdrinfo b in
    check_fmt "monotone timestamps" (!last_time <= time);
    last_time := time;
    begin match ev with
    | Ev_location ->
      let (id, loc) = get_backtrace_slot file_mtf b in
      (*Printf.printf "%3d _ _ location\n" (b.pos - last_pos);*)
      if Hashtbl.mem loc_table id then
        check_fmt "consistent location info" (Hashtbl.find loc_table id = loc)
      else
        Hashtbl.add loc_table id loc
    | Ev_alloc ->
      let info = get_alloc cache !alloc_id b in
      incr alloc_id;
      (*Printf.printf "%3d " (b.pos - last_pos);*)
      f time info
    | Ev_collect ->
      let info = get_collect !alloc_id b in
      (*Printf.printf "%3d " (b.pos - last_pos);*)
      f time info
    | Ev_promote ->
      let info = get_promote !alloc_id b in
      (*Printf.printf "%3d " (b.pos - last_pos);*)
      f time info
    end
  done;
  check_fmt "alloc id sync" (hdrinfo.alloc_id_end = Int64.of_int (!alloc_id))

let parse_trace filename loc_table f =
  let cache = create_reader_cache () in
  let file_mtf = create_mtf_table () in
  let fd = Unix.openfile filename [Unix.O_RDONLY] 0 in
  (* FIXME error handling *)
  let buf = Bytes.make 1_000_000 '\000' in
  let rec read_into buf off =
    assert (0 <= off && off <= Bytes.length buf);
    if off = Bytes.length buf then
      { buf; pos = 0; pos_end = off }
    else begin
      let n = Unix.read fd buf off (Bytes.length buf - off) in
      if n = 0 then
        (* EOF *)
        { buf; pos = 0; pos_end = off }
      else
        read_into buf (off + n)
    end in
  let refill b =
    let len = remaining b in
    Bytes.blit b.buf b.pos b.buf 0 len;
    read_into b.buf len in
  let rec go last_timestamp last_alloc_id b =
    let b = if remaining b < 4096 then refill b else b in
    if remaining b = 0 then () else
    let info = get_ctf_header b in
    check_fmt "monotone inter-packet times" (last_timestamp <= info.time_begin);
    check_fmt "inter-packet alloc ID" (last_alloc_id = info.alloc_id_begin);
    let len = info.content_size in
    let b = if remaining b < len then refill b else b in
    parse_packet_events file_mtf loc_table cache info { b with pos_end = b.pos + len } f;
    go info.time_end info.alloc_id_end { b with pos = b.pos + len } in
  go 0L 0L { buf; pos = 0; pos_end = 0 };
  Unix.close fd


let[@inline always] beep i = ((i * 483205) land 0xfffff, i)
let[@inline always] mul i = let m = beep i in assert (i >= 0); m

let write () =
  let out = Unix.openfile "memtrace.ctf" [Unix.O_CREAT;Unix.O_WRONLY;Unix.O_TRUNC] 0o600 in
  let s = start_memprof out 0.001 in
  let module S = Set.Make (struct type t = (int * int) option let compare = compare end) in
  List.init 10_000 (fun i -> Some (if i < -100 then assert false else mul i))
  |> List.map (fun x -> (*Unix.sleepf 0.001;*) S.singleton x)
  |> List.fold_left S.union S.empty
  |> Sys.opaque_identity
  |> ignore;
  Gc.full_major ();
  stop_memprof s


let read () =
  let filename = "memtrace.ctf" in
  let loc_table = Hashtbl.create 20 in
  parse_trace filename loc_table (fun time ev ->
    Printf.printf "%010f " time;
    match ev with
  | Alloc {obj_id; length; nsamples; is_major; common_prefix; new_suffix} ->
    Printf.printf "%010d alloc %d %d %b %d:" obj_id length nsamples is_major common_prefix;
    let print_location ppf { filename; line; start_char; end_char  } =
      Printf.fprintf ppf "%s:%d:%d-%d" filename line start_char end_char in
    new_suffix |> List.iter (fun s ->
      Hashtbl.find loc_table s |> List.iter (Printf.printf " %a" print_location));
    Printf.printf "\n%!"
  | Promote id ->
    Printf.printf "%010d promote\n" id
  | Collect id ->
    Printf.printf "%010d collect\n" id);
  Printf.printf "end\n%!"


module StrTbl = Hashtbl.Make(struct type t = string let equal = String.equal let hash = Hashtbl.hash end)
type summary = {
  mutable samples: int;
  subsums : summary StrTbl.t;
}

let summary () =
  let filename = "memtrace.ctf" in
  let loc_table = Hashtbl.create 20 in
  let last = ref [| |] in
  let summary = { samples = 0; subsums = StrTbl.create 20 } in
  let count (filenames, nsamples) =
    let lastsum =
      List.fold_left (fun sum f ->
        if StrTbl.mem sum.subsums f then
          StrTbl.find sum.subsums f
        else begin
          let s = { samples = 0; subsums = StrTbl.create 10 } in
          StrTbl.add sum.subsums f s;
          s
        end) summary filenames in
    lastsum.samples <- lastsum.samples + nsamples in

  let allocs = Hashtbl.create 20 in
  let sz = ref 0 in
  let nallocs = ref 0 in
  parse_trace filename loc_table (fun time ev ->
    match ev with
  | Alloc {obj_id; length; nsamples; is_major; common_prefix; new_suffix} ->
    let bt = Array.concat [Array.sub !last 0 common_prefix; Array.of_list new_suffix] in
    last := bt;
    let str_of_location { filename; line; start_char; end_char  } =
      Printf.sprintf "%s:%d" filename line in
    let print_location ppf { filename; line; start_char; end_char  } =
      Printf.fprintf ppf "%s:%d:%d-%d" filename line start_char end_char in
    let filenames = List.concat (bt |> Array.map (fun l ->
      let locs = Hashtbl.find loc_table l in
      List.map (fun ({ filename; _ } as l) -> str_of_location l) locs) |> Array.to_list) in
    let seen = StrTbl.create 10 in
    let rec dedup = function
      | [] -> []
      | [x] -> [x]
      | x :: x' :: xs when x = x' -> dedup (x :: xs)
      | x :: xs -> x :: dedup xs in
    let filenames = dedup filenames in
    let first_filenames =
      filenames |> List.filter (fun f ->
        if StrTbl.mem seen f then false else begin
          StrTbl.add seen f ();
          true
        end) in
    Hashtbl.add allocs obj_id (first_filenames, nsamples);
    sz := !sz + common_prefix + List.length new_suffix;
    incr nallocs;
    if true then count (filenames, nsamples);
    (* count (first_filenames, nsamples) *)
(*    first_filenames |> List.iter (Printf.printf " %s");
      Printf.printf "\n%!"*)
  | Promote i -> ()
  (*count (Hashtbl.find allocs i)*)
  | Collect i -> assert (Hashtbl.mem allocs i); Hashtbl.remove allocs i );

  let rec dump_summary files_rev summary =
    if summary.samples > 0 then begin match List.rev files_rev with
    | [] -> ()
    | [_] -> ()
    | (x :: xs) ->
      Printf.printf "%s" x;
      List.iter (Printf.printf ";%s") xs;
      Printf.printf " %d\n" summary.samples
    end;
    let keys = StrTbl.fold (fun k _ ks -> k :: ks) summary.subsums [] |> List.sort String.compare in
    keys |> List.iter (fun f ->
      let s = StrTbl.find summary.subsums f in
      dump_summary (f :: files_rev) s) in
  dump_summary [] summary;
  Printf.fprintf stderr "sz/kb %d\nallocs %d\n" (!sz / 1024) !nallocs


let () =
  if Array.length Sys.argv = 1 then
    write ()
  else
    try
      summary ()
    with
    | Parse_error (`Bad_format s) -> Printf.printf "parse error: %s\n" s
