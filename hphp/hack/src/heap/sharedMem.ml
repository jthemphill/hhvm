(*
 * Copyright (c) 2015, Facebook, Inc.
 * All rights reserved.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the "hack" directory of this source tree.
 *
 *)

open Hh_prelude
module Hashtbl = Stdlib.Hashtbl
module Queue = Stdlib.Queue
module Set = Stdlib.Set

(** This is just a sentinel for self-documenting purposes which some
parts of the codebase use. They take a parameter "uses_sharedmem : SharedMem.uses"
as a way to indicate to their callers that they read/write sharedmem. *)
type uses = Uses

let ref_has_done_init = ref false

(* Don't change the ordering of this record without updating hh_shared_init in
 * hh_shared.c, which indexes into config objects *)
type config = {
  global_size: int;
  heap_size: int;
  dep_table_pow: int;
  hash_table_pow: int;
  shm_dirs: string list;
  shm_min_avail: int;
  log_level: int;
  sample_rate: float;
}
[@@deriving show]

let default_config =
  let gig = 1024 * 1024 * 1024 in
  {
    global_size = gig;
    heap_size = 20 * gig;
    dep_table_pow = 17;
    (* 1 << 17 *)
    hash_table_pow = 18;
    (* 1 << 18 *)
    shm_dirs = [GlobalConfig.shm_dir; GlobalConfig.tmp_dir];
    shm_min_avail = gig / 2;
    (* Half a gig by default *)
    log_level = 0;
    sample_rate = 0.0;
  }

(* There are places where we don't expect to write to shared memory, and doing
 * so would be a memory leak. But since shared memory is global, it's very easy
 * to accidentally call a function that will attempt such write. Setting all the
 * sizes to 0 will make it fail immediately. *)
let empty_config =
  {
    global_size = 0;
    heap_size = 0;
    dep_table_pow = 0;
    hash_table_pow = 0;
    shm_dirs = [];
    shm_min_avail = 0;
    log_level = 0;
    sample_rate = 0.0;
  }

(* Allocated in C only. *)
type handle = private {
  h_fd: Unix.file_descr;
  h_global_size: int;
  h_heap_size: int;
}

(* Allocated in C only. *)
type serialized = private bytes

exception Out_of_shared_memory

exception Hash_table_full

exception Dep_table_full

exception Heap_full

exception Revision_length_is_zero

exception Sql_assertion_failure of int

exception Failed_anonymous_memfd_init

exception Less_than_minimum_available of int

exception Failed_to_use_shm_dir of string

exception C_assertion_failure of string

let () =
  Callback.register_exception "out_of_shared_memory" Out_of_shared_memory;
  Callback.register_exception "hash_table_full" Hash_table_full;
  Callback.register_exception "dep_table_full" Dep_table_full;
  Callback.register_exception "heap_full" Heap_full;
  Callback.register_exception "revision_length_is_zero" Revision_length_is_zero;
  Callback.register_exception "sql_assertion_failure" (Sql_assertion_failure 0);
  Callback.register_exception
    "failed_anonymous_memfd_init"
    Failed_anonymous_memfd_init;
  Callback.register_exception
    "less_than_minimum_available"
    (Less_than_minimum_available 0);
  Callback.register_exception
    "c_assertion_failure"
    (C_assertion_failure "dummy string")

(*****************************************************************************)
(* Each cache can write telemetry about its current occupancy.
 * - Immediate caches - only records its existence
 * - WithLocalChanges caches - they do Obj.reachable_words to count up the stack
 * - Local caches - they do Obj.reachable_words
 * In the case of compound caches, e.g. WithCache which includes all three,
 * it doesn't have to report telemetry since each of its constituents already
 * reports telemetry on its own.
 * Anyway, each cache registers in the global "get_telemetry_list" so that
 * callers can do SharedMem.get_telemetry and pick up from all caches.
 *
 * Caveats:
 * Note that Obj.reachable_words may double-count stuff if it's in both
 * Local and WithLocalChanges cache. It may also take time, up to ~300ms.
 * And it will be meaningless if the items in the Local cache have references
 * into other parts of the system. It's up to the reader to make sense of it.
 *
 * The "WithLocalChanges" doesn't have a straightforward count of elements.
 * Instead it counts how many "actions" there are across all change-stacks:
 * how many adds, removes, replaces.
 *)
(*****************************************************************************)

let get_telemetry_list = ref []

let get_telemetry () : Telemetry.t =
  (* This function gets called by compute_tast, even in places which
  deliberately don't initialize shared memory. In these places, no-op,
  since otherwise reading from hh_log_level would segfault. *)
  if not !ref_has_done_init then
    Telemetry.create ()
  else
    let start_time = Unix.gettimeofday () in
    let telemetry =
      List.fold
        !get_telemetry_list
        ~init:(Telemetry.create ())
        ~f:(fun acc get_telemetry -> get_telemetry acc)
    in
    telemetry |> Telemetry.duration ~start_time

(*****************************************************************************)
(* Initializes the shared memory. Must be called before forking. *)
(*****************************************************************************)
external hh_shared_init :
  config:config -> shm_dir:string option -> num_workers:int -> handle
  = "hh_shared_init"

let anonymous_init config ~num_workers =
  hh_shared_init ~config ~shm_dir:None ~num_workers

let rec shm_dir_init config ~num_workers = function
  | [] ->
    Hh_logger.log "We've run out of filesystems to use for shared memory";
    raise Out_of_shared_memory
  | shm_dir :: shm_dirs ->
    let shm_min_avail = config.shm_min_avail in
    begin
      (* For some reason statvfs is segfaulting when the directory doesn't
       * exist, instead of returning -1 and an errno *)
      try
        if not (Sys.file_exists shm_dir) then
          raise (Failed_to_use_shm_dir "shm_dir does not exist");
        hh_shared_init ~config ~shm_dir:(Some shm_dir) ~num_workers
      with
      | Less_than_minimum_available avail ->
        EventLogger.(
          log_if_initialized (fun () ->
              sharedmem_less_than_minimum_available
                ~shm_dir
                ~shm_min_avail
                ~avail));
        Hh_logger.log
          "Filesystem %s only has %d bytes available, which is less than the minimum %d bytes"
          shm_dir
          avail
          config.shm_min_avail;
        shm_dir_init config ~num_workers shm_dirs
      | Unix.Unix_error (e, fn, arg) ->
        let fn_string =
          if String.equal fn "" then
            ""
          else
            Utils.spf " thrown by %s(%s)" fn arg
        in
        let reason =
          Utils.spf "Unix error%s: %s" fn_string (Unix.error_message e)
        in
        EventLogger.(
          log_if_initialized (fun () ->
              sharedmem_failed_to_use_shm_dir ~shm_dir ~reason));
        Hh_logger.log "Failed to use shm dir `%s`: %s" shm_dir reason;
        shm_dir_init config ~num_workers shm_dirs
      | Failed_to_use_shm_dir reason ->
        EventLogger.(
          log_if_initialized (fun () ->
              sharedmem_failed_to_use_shm_dir ~shm_dir ~reason));
        Hh_logger.log "Failed to use shm dir `%s`: %s" shm_dir reason;
        shm_dir_init config ~num_workers shm_dirs
    end

let init config ~num_workers =
  ref_has_done_init := true;
  try anonymous_init config ~num_workers
  with Failed_anonymous_memfd_init ->
    EventLogger.(
      log_if_initialized (fun () -> sharedmem_failed_anonymous_memfd_init ()));
    Hh_logger.log "Failed to use anonymous memfd init";
    shm_dir_init config ~num_workers config.shm_dirs

external allow_removes : bool -> unit = "hh_allow_removes"

external allow_hashtable_writes_by_current_process : bool -> unit
  = "hh_allow_hashtable_writes_by_current_process"

external connect : handle -> worker_id:int -> unit = "hh_connect"

external get_handle : unit -> handle = "hh_get_handle"

external get_worker_id : unit -> int = "hh_get_worker_id" [@@noalloc]

(*****************************************************************************)
(* Raw access for proxying across network.
 *)
(*****************************************************************************)
external mem_raw : string -> bool = "hh_mem"

external get_raw : string -> serialized = "hh_get_raw"

external add_raw : string -> serialized -> unit = "hh_add_raw"

external deserialize_raw : serialized -> 'a = "hh_deserialize_raw"

external serialize_raw : 'a -> serialized = "hh_serialize_raw"

(*****************************************************************************)
(* The shared memory garbage collector. It must be called every time we
 * free data (cf hh_shared.c for the underlying C implementation).
 *)
(*****************************************************************************)
external hh_collect : unit -> unit = "hh_collect" [@@noalloc]

(*****************************************************************************)
(* Serializes the dependency table and writes it to a file *)
(*****************************************************************************)

external loaded_dep_table_filename_c : unit -> string
  = "hh_get_loaded_dep_table_filename"

external get_in_memory_dep_table_entry_count : unit -> int
  = "hh_get_in_memory_dep_table_entry_count"

let loaded_dep_table_filename () =
  let fn = loaded_dep_table_filename_c () in
  if String.equal "" fn then
    None
  else
    Some fn

external save_dep_table_blob_c : string -> string -> bool -> int
  = "hh_save_dep_table_blob"

(* Returns number of dependency edges added. *)
external save_dep_table_sqlite_c : string -> string -> bool -> int
  = "hh_save_dep_table_sqlite"

(* Returns number of dependency edges added. *)
external update_dep_table_sqlite_c : string -> string -> bool -> int
  = "hh_update_dep_table_sqlite"

let save_dep_table_sqlite fn build_revision ~replace_state_after_saving =
  if Option.is_some (loaded_dep_table_filename ()) then
    failwith
      "save_dep_table_sqlite not supported when server is loaded from a saved state; use update_dep_table_sqlite";
  Hh_logger.log "Dumping a saved state deptable into a SQLite DB.";
  save_dep_table_sqlite_c fn build_revision replace_state_after_saving

let save_dep_table_blob fn build_revision ~reset_state_after_saving =
  if Option.is_some (loaded_dep_table_filename ()) then
    failwith
      "save_dep_table_blob not supported when the server is loaded from a saved state; use update_dep_table_sqlite";
  Hh_logger.log "Dumping a saved state deptable as a blob.";

  save_dep_table_blob_c fn build_revision reset_state_after_saving

let update_dep_table_sqlite : string -> string -> bool -> int =
 fun fn build_revision replace_state_after_saving ->
  Hh_logger.log "Updating given saved state deptable.";
  update_dep_table_sqlite_c fn build_revision replace_state_after_saving

(*****************************************************************************)
(* Loads the dependency table by reading from a file                         *)
(*****************************************************************************)

external load_dep_table_blob_c : string -> bool -> int
  = "hh_load_dep_table_blob"

external load_dep_table_sqlite_c : string -> bool -> unit
  = "hh_load_dep_table_sqlite"

(* Returns the number of edges added *)
let load_dep_table_blob : string -> bool -> int =
 (fun fn ignore_hh_version -> load_dep_table_blob_c fn ignore_hh_version)

let load_dep_table_sqlite : string -> bool -> unit =
 (fun fn ignore_hh_version -> load_dep_table_sqlite_c fn ignore_hh_version)

(*****************************************************************************)
(* Cleans up the artifacts generated by SQLite *)
(*****************************************************************************)
external cleanup_sqlite : unit -> unit = "hh_cleanup_sqlite"

(*****************************************************************************)
(* The size of the dynamically allocated shared memory section *)
(*****************************************************************************)
external heap_size : unit -> int = "hh_used_heap_size" [@@noalloc]

(*****************************************************************************)
(* Part of the heap not reachable from hashtable entries. *)
(*****************************************************************************)
external wasted_heap_size : unit -> int = "hh_wasted_heap_size" [@@noalloc]

(*****************************************************************************)
(* The logging level for shared memory statistics *)
(* 0 = nothing *)
(* 1 = log totals, averages, min, max bytes marshalled and unmarshalled *)
(*****************************************************************************)
external hh_log_level : unit -> int = "hh_log_level" [@@noalloc]

(*****************************************************************************)
(* The sample rate for shared memory statistics *)
(*****************************************************************************)
external hh_sample_rate : unit -> float = "hh_sample_rate"

(*****************************************************************************)
(* The number of used slots in our hashtable *)
(*****************************************************************************)
external hash_used_slots : unit -> int * int = "hh_hash_used_slots"

(*****************************************************************************)
(* The total number of slots in our hashtable *)
(*****************************************************************************)
external hash_slots : unit -> int = "hh_hash_slots"

(*****************************************************************************)
(* The number of used slots in our dependency table *)
(*****************************************************************************)
external dep_used_slots : unit -> int = "hh_dep_used_slots"

(*****************************************************************************)
(* The total number of slots in our dependency table *)
(*****************************************************************************)
external dep_slots : unit -> int = "hh_dep_slots"

(*****************************************************************************)
(* Must be called after the initialization of the hack server is over.
 * (cf serverInit.ml). *)
(*****************************************************************************)

external hh_removed_count : unit -> int = "hh_removed_count"

external hh_check_heap_overflow : unit -> bool = "hh_check_heap_overflow"

let init_done () = EventLogger.sharedmem_init_done (heap_size ())

type table_stats = {
  nonempty_slots: int;
  used_slots: int;
  slots: int;
}

let dep_stats () =
  let used = dep_used_slots () in
  { nonempty_slots = used; used_slots = used; slots = dep_slots () }

let hash_stats () =
  let (used_slots, nonempty_slots) = hash_used_slots () in
  { nonempty_slots; used_slots; slots = hash_slots () }

let should_collect (effort : [ `gentle | `aggressive | `always_TEST ]) =
  let overhead =
    match effort with
    | `always_TEST -> 1.0
    | `aggressive -> 1.2
    | `gentle -> 2.0
  in
  let used = heap_size () in
  let wasted = wasted_heap_size () in
  let reachable = used - wasted in
  used >= Float.iround_towards_zero_exn (float reachable *. overhead)

let collect (effort : [ `gentle | `aggressive | `always_TEST ]) =
  let old_size = heap_size () in
  Stats.update_max_heap_size old_size;
  let start_t = Unix.gettimeofday () in
  (* The wrapper is used to run the function in a worker instead of master. *)
  if should_collect effort then hh_collect ();
  let new_size = heap_size () in
  let time_taken = Unix.gettimeofday () -. start_t in
  if old_size <> new_size then (
    Hh_logger.log
      "Sharedmem GC: %d bytes before; %d bytes after; in %f seconds"
      old_size
      new_size
      time_taken;
    EventLogger.sharedmem_gc_ran effort old_size new_size time_taken
  )

let is_heap_overflow () = hh_check_heap_overflow ()

(*****************************************************************************)
(* Compute size of values in the garbage-collected heap *)
(*****************************************************************************)

let value_size r =
  let w = Obj.reachable_words r in
  w * (Sys.word_size / 8)

(*****************************************************************************)
(* Module returning the MD5 of the key. It's because the code in C land
 * expects this format. I prefer to make it an abstract type to make sure
 * we don't forget to give the MD5 instead of the key itself.
 *)
(*****************************************************************************)

module type Key = sig
  (* The type of keys that OCaml-land callers try to insert *)
  type userkey

  (* The type of keys that get stored in the C hashtable *)
  type t

  (* The type of old keys that get stored in the C hashtable *)
  type old

  (* The md5 of an old or a new key *)
  type md5

  (* Creation/conversion primitives *)
  val make : Prefix.t -> userkey -> t

  val make_old : Prefix.t -> userkey -> old

  val to_old : t -> old

  val new_from_old : old -> t

  (* Md5 primitives *)
  val md5 : t -> md5

  val md5_old : old -> md5

  val string_of_md5 : md5 -> string
end

module KeyFunctor (UserKeyType : sig
  type t

  val to_string : t -> string
end) : Key with type userkey = UserKeyType.t = struct
  type userkey = UserKeyType.t

  type t = string

  type old = string

  type md5 = string

  (* The prefix we use for old keys. The prefix guarantees that we never
   * mix old and new data, because a key can never start with the prefix
   * "old_", it always starts with a number (cf Prefix.make()).
   *)
  let old_prefix = "old_"

  let make : Prefix.t -> userkey -> t =
   (fun prefix x -> Prefix.make_key prefix (UserKeyType.to_string x))

  let make_old : Prefix.t -> userkey -> old =
   fun prefix x ->
    old_prefix ^ Prefix.make_key prefix (UserKeyType.to_string x)

  let to_old : t -> old = (fun x -> old_prefix ^ x)

  let new_from_old : old -> t =
   fun x ->
    let module S = String in
    S.sub x (S.length old_prefix) (S.length x - S.length old_prefix)

  let md5 : t -> md5 = Stdlib.Digest.string

  let md5_old : old -> md5 = Stdlib.Digest.string

  let string_of_md5 : md5 -> string = (fun x -> x)
end

module type Raw = functor (Key : Key) (Value : Value.Type) -> sig
  val add : Key.md5 -> Value.t -> unit

  val mem : Key.md5 -> bool

  val get : Key.md5 -> Value.t

  val remove : Key.md5 -> unit

  val move : Key.md5 -> Key.md5 -> unit
end

(*****************************************************************************)
(* Some heaps are parameterized by how many local (ocaml heap) items they    *)
(* can fit.                                                                  *)
(*****************************************************************************)

module type LocalCapacityType = sig
  val capacity : int
end

(*****************************************************************************)
(* Immediate access to shared memory (cf hh_shared.c for the underlying
 * representation).
 *)
(*****************************************************************************)
module Immediate (Key : Key) (Value : Value.Type) : sig
  val add : Key.md5 -> Value.t -> unit

  val mem : Key.md5 -> bool

  val get : Key.md5 -> Value.t

  val remove : Key.md5 -> unit

  val move : Key.md5 -> Key.md5 -> unit
end = struct
  (* Returns the number of bytes allocated in the heap, or a negative number
   * if no new memory was allocated *)
  external hh_add : Key.md5 -> Value.t -> int * int * int = "hh_add"

  external hh_mem : Key.md5 -> bool = "hh_mem"

  external hh_mem_status : Key.md5 -> int = "hh_mem_status"

  external hh_get_size : Key.md5 -> int = "hh_get_size"

  external hh_get_and_deserialize : Key.md5 -> Value.t
    = "hh_get_and_deserialize"

  external hh_remove : Key.md5 -> int = "hh_remove"

  external hh_move : Key.md5 -> Key.md5 -> unit = "hh_move"

  let _ = hh_mem_status

  let measure_add = Value.description ^ " (bytes serialized into shared heap)"

  let measure_remove =
    Value.description ^ " (compressed bytes removed from shared heap)"

  let measure_get = Value.description ^ " (bytes deserialized from shared heap)"

  let log_serialize compressed original total =
    let compressed = float compressed in
    let original = float original in
    let total = float total in
    let saved = original -. compressed in
    let ratio = compressed /. original in
    Measure.sample
      (Value.description ^ " (total bytes including header and padding)")
      total;
    Measure.sample "ALL bytes (total bytes including header and padding)" total;
    Measure.sample measure_add compressed;
    Measure.sample "ALL bytes serialized into shared heap" compressed;
    Measure.sample
      (Value.description ^ " (bytes saved in shared heap due to compression)")
      saved;
    Measure.sample "ALL bytes saved in shared heap due to compression" saved;
    Measure.sample
      (Value.description ^ " (shared heap compression ratio)")
      ratio;
    Measure.sample "ALL bytes shared heap compression ratio" ratio

  let log_deserialize l r =
    let sharedheap = float l in
    Measure.sample measure_get sharedheap;
    Measure.sample "ALL bytes deserialized from shared heap" sharedheap;

    if hh_log_level () > 1 then (
      (* value_size is a bit expensive to call this often, so only run with log levels >= 2 *)
      let localheap = float (value_size r) in
      Measure.sample
        (Value.description ^ " (bytes allocated for deserialized value)")
        localheap;
      Measure.sample "ALL bytes allocated for deserialized value" localheap
    )

  let log_remove compressed =
    let compressed = float compressed in
    Measure.sample measure_remove compressed;
    Measure.sample "ALL compressed bytes removed from shared heap" compressed;
    ()

  let add key value =
    let (compressed_size, original_size, total_size) = hh_add key value in
    (* compressed_size is a negative number if nothing new was added *)
    if hh_log_level () > 0 && compressed_size > 0 then
      log_serialize compressed_size original_size total_size

  let mem key = hh_mem key

  let get key =
    let v = hh_get_and_deserialize key in
    if hh_log_level () > 0 then log_deserialize (hh_get_size key) (Obj.repr v);
    v

  let remove key =
    let compressed_size = hh_remove key in
    (* hh_remove assumes the key is present *)
    if hh_log_level () > 0 then log_remove compressed_size;
    ()

  let move from_key to_key = hh_move from_key to_key

  let get_telemetry (telemetry : Telemetry.t) : Telemetry.t =
    let simple_metric name = (Measure.get_count name, Measure.get_sum name) in
    let diff_metric left_name right_name =
      let diff left right = Option.merge left ~f:( -. ) right in
      let (left_count, left_bytes) = simple_metric left_name in
      let (right_count, right_bytes) = simple_metric right_name in
      (diff left_count right_count, diff left_bytes right_bytes)
    in
    (* Gather counts and sums for these metrics *)
    let metrics =
      [
        ("get", simple_metric measure_get);
        ("add", simple_metric measure_add);
        ("remove", simple_metric measure_remove);
        ("entries", diff_metric measure_add measure_remove);
      ]
    in
    let is_none = function
      | (_, (None, None)) -> true
      | _ -> false
    in
    if List.for_all ~f:is_none metrics then
      telemetry
    else
      let make_obj t (key, (count, bytes)) =
        let count_val = Option.value_map ~default:0 ~f:int_of_float count in
        let bytes_val = Option.value_map ~default:0 ~f:int_of_float bytes in
        Telemetry.object_
          ~key
          ~value:
            ( Telemetry.create ()
            |> Telemetry.int_ ~key:"count" ~value:count_val
            |> Telemetry.int_ ~key:"bytes" ~value:bytes_val )
          t
      in
      let value = List.fold ~f:make_obj ~init:(Telemetry.create ()) metrics in
      telemetry
      |> Telemetry.object_ ~key:(Value.description ^ "__shared") ~value

  let () =
    get_telemetry_list := get_telemetry :: !get_telemetry_list;
    ()
end

type 'a profiled_value =
  | RawValue of 'a
  | ProfiledValue of {
      entry: 'a;
      write_time: float;
    }

module ProfiledImmediate : functor (Key : Key) (Value : Value.Type) -> sig
  include module type of Immediate (Key) (Value)
end =
functor
  (Key : Key)
  (Value : Value.Type)
  ->
  struct
    module ProfiledValue = struct
      (** Tagging a value as Raw (the 99.9999% case) only increases its marshalled
        size by 1 byte, and does not change its unmarshalled memory
        representation provided Value.t is a record type containing at least one
        non-float member. *)
      type t = Value.t profiled_value

      let prefix = Value.prefix

      let description = Value.description
    end

    module Immediate = Immediate (Key) (ProfiledValue)

    let add x y =
      let sample_rate = hh_sample_rate () in
      let entry =
        if hh_log_level () <> 0 && Float.(Random.float 1.0 < sample_rate) then
          ProfiledValue { entry = y; write_time = Unix.gettimeofday () }
        else
          RawValue y
      in
      Immediate.add x entry

    let get x =
      match Immediate.get x with
      | RawValue y -> y
      | ProfiledValue { entry; write_time } ->
        EventLogger.(
          log_if_initialized @@ fun () ->
          sharedmem_access_sample
            ~heap_name:Value.description
            ~key:(Key.string_of_md5 x)
            ~write_time);
        entry

    let mem = Immediate.mem

    let remove = Immediate.remove

    let move = Immediate.move
  end

(*****************************************************************************)
(* Direct access to shared memory, but with a layer of local changes that allow
 * us to decide whether or not to commit specific values.
 *)
(*****************************************************************************)
module WithLocalChanges : functor
  (Raw : Raw)
  (Key : Key)
  (Value : Value.Type)
  -> sig
  include module type of Raw (Key) (Value)

  module LocalChanges : sig
    val has_local_changes : unit -> bool

    val push_stack : unit -> unit

    val pop_stack : unit -> unit

    val revert : Key.md5 -> unit

    val commit : Key.md5 -> unit

    val revert_all : unit -> unit

    val commit_all : unit -> unit
  end
end =
functor
  (Raw : Raw)
  (Key : Key)
  (Value : Value.Type)
  ->
  struct
    module Raw = Raw (Key) (Value)

    (**
      Represents a set of local changes to the view of the shared memory heap
      WITHOUT materializing to the changes in the actual heap. This allows us to
      make speculative changes to the view of the world that can be reverted
      quickly and correctly.

      A LocalChanges maintains the same invariants as the shared heap. Except
      add are allowed to overwrite filled keys. This is for convenience so we
      do not need to remove filled keys upfront.

      LocalChanges can be committed. This will apply the changes to the previous
      stack, or directly to shared memory if there are no other active stacks.
      Since changes are kept local to the process, this is NOT compatible with
      the parallelism provided by MultiWorker.ml
      *)
    module LocalChanges = struct
      type action =
        (* The value does not exist in the current stack. When committed this
         * action will invoke remove on the previous stack.
         *)
        | Remove
        (* The value is added to a previously empty slot. When committed this
         * action will invoke add on the previous stack.
         *)
        | Add of Value.t
        (* The value is replacing a value already associated with a key in the
         * previous stack. When committed this action will invoke remove then
         * add on the previous stack.
         *)
        | Replace of Value.t

      type t = {
        current: (Key.md5, action) Hashtbl.t;
        prev: t option;
      }

      let stack : t option ref = ref None

      let has_local_changes () = Option.is_some !stack

      let rec mem stack_opt key =
        match stack_opt with
        | None -> Raw.mem key
        | Some stack ->
          (match Hashtbl.find_opt stack.current key with
          | Some Remove -> false
          | Some _ -> true
          | None -> mem stack.prev key)

      let rec get stack_opt key =
        match stack_opt with
        | None -> Raw.get key
        | Some stack ->
          (match Hashtbl.find_opt stack.current key with
          | Some Remove -> failwith "Trying to get a non-existent value"
          | Some (Replace value | Add value) -> value
          | None -> get stack.prev key)

      (*
       * For remove/add it is best to think of them in terms of a state machine.
       * A key can be in the following states:
       *
       *  Remove:
       *    Local changeset removes a key from the previous stack
       *  Replace:
       *    Local changeset replaces value of a key in previous stack
       *  Add:
       *    Local changeset associates a value with a key. The key is not
       *    present in the previous stacks
       *  Empty:
       *    No local changes and key is not present in previous stack
       *  Filled:
       *    No local changes and key has an associated value in previous stack
       *  *Error*:
       *    This means an exception will occur
       *)
      (*
       * Transitions table:
       *   Remove  -> *Error*
       *   Replace -> Remove
       *   Add     -> Empty
       *   Empty   -> *Error*
       *   Filled  -> Remove
       *)
      let remove stack_opt key =
        match stack_opt with
        | None -> Raw.remove key
        | Some stack ->
          (match Hashtbl.find_opt stack.current key with
          | Some Remove -> failwith "Trying to remove a non-existent value"
          | Some (Replace _) -> Hashtbl.replace stack.current key Remove
          | Some (Add _) -> Hashtbl.remove stack.current key
          | None ->
            if mem stack.prev key then
              Hashtbl.replace stack.current key Remove
            else
              failwith "Trying to remove a non-existent value")

      (*
       * Transitions table:
       *   Remove  -> Replace
       *   Replace -> Replace
       *   Add     -> Add
       *   Empty   -> Add
       *   Filled  -> Replace
       *)
      let add stack_opt key value =
        match stack_opt with
        | None -> Raw.add key value
        | Some stack ->
          (match Hashtbl.find_opt stack.current key with
          | Some (Remove | Replace _) ->
            Hashtbl.replace stack.current key (Replace value)
          | Some (Add _) -> Hashtbl.replace stack.current key (Add value)
          | None ->
            if mem stack.prev key then
              Hashtbl.replace stack.current key (Replace value)
            else
              Hashtbl.replace stack.current key (Add value))

      let move stack_opt from_key to_key =
        match stack_opt with
        | None -> Raw.move from_key to_key
        | Some _stack ->
          assert (mem stack_opt from_key);
          assert (not @@ mem stack_opt to_key);
          let value = get stack_opt from_key in
          remove stack_opt from_key;
          add stack_opt to_key value

      let commit_action changeset key elem =
        match elem with
        | Remove -> remove changeset key
        | Add value -> add changeset key value
        | Replace value ->
          remove changeset key;
          add changeset key value

      (* Public API **)
      let push_stack () =
        stack := Some { current = Hashtbl.create 128; prev = !stack }

      let pop_stack () =
        match !stack with
        | None ->
          failwith "There are no active local change stacks. Nothing to pop!"
        | Some { prev; _ } -> stack := prev

      let revert key =
        match !stack with
        | None -> ()
        | Some changeset -> Hashtbl.remove changeset.current key

      let commit key =
        match !stack with
        | None -> ()
        | Some changeset ->
          (match Hashtbl.find_opt changeset.current key with
          | None -> ()
          | Some r -> commit_action changeset.prev key r)

      let revert_all () =
        match !stack with
        | None -> ()
        | Some changeset -> Hashtbl.clear changeset.current

      let commit_all () =
        match !stack with
        | None -> ()
        | Some changeset ->
          Hashtbl.iter (commit_action changeset.prev) changeset.current

      let get_telemetry (telemetry : Telemetry.t) : Telemetry.t =
        let rec rec_actions_and_depth acc_count acc_depth changeset_opt =
          match changeset_opt with
          | Some changeset ->
            rec_actions_and_depth
              (acc_count + Hashtbl.length changeset.current)
              (acc_depth + 1)
              changeset.prev
          | None -> (acc_count, acc_depth)
        in
        let (actions, depth) = rec_actions_and_depth 0 0 !stack in
        (* We count reachable words of the entire stack, to avoid double-
        counting in cases where a value appears in multiple stack frames.
        If instead we added up reachable words from each frame separately,
        then an item reachable from two frames would be double-counted. *)
        let bytes =
          if hh_log_level () > 0 then
            Some (Obj.reachable_words (Obj.repr !stack) * (Sys.word_size / 8))
          else
            None
        in
        if actions = 0 then
          telemetry
        else
          telemetry
          |> Telemetry.object_
               ~key:(Value.description ^ "__stack")
               ~value:
                 ( Telemetry.create ()
                 |> Telemetry.int_ ~key:"actions" ~value:actions
                 |> Telemetry.int_opt ~key:"bytes" ~value:bytes
                 |> Telemetry.int_ ~key:"depth" ~value:depth )

      let () =
        get_telemetry_list := get_telemetry :: !get_telemetry_list;
        ()
    end

    let add key value = LocalChanges.(add !stack key value)

    let mem key = LocalChanges.(mem !stack key)

    let get key = LocalChanges.(get !stack key)

    let remove key = LocalChanges.(remove !stack key)

    let move from_key to_key = LocalChanges.(move !stack from_key to_key)
  end

(*****************************************************************************)
(* Module used to access "new" values (as opposed to old ones).
 * There are several cases where we need to compare the old and the new
 * representation of objects (to determine what has changed).
 * The "old" representation is the value that was bound to that key in the
 * last round of type-checking.
 * Despite the fact that the same storage is used under the hood, it's good
 * to separate the two interfaces to make sure we never mix old and new
 * values.
 *)
(*****************************************************************************)

module New : functor (Raw : Raw) (Key : Key) (Value : Value.Type) -> sig
  (* Adds a binding to the table, the table is left unchanged if the
   * key was already bound.
   *)
  val add : Key.t -> Value.t -> unit

  val get : Key.t -> Value.t option

  val find_unsafe : Key.t -> Value.t

  val remove : Key.t -> unit

  val mem : Key.t -> bool

  (* Binds the key to the old one.
   * If 'mykey' is bound to 'myvalue', oldifying 'mykey' makes 'mykey'
   * accessible to the "Old" module, in other words: "Old.mem mykey" returns
   * true and "New.mem mykey" returns false after oldifying.
   *)
  val oldify : Key.t -> unit

  module WithLocalChanges : module type of WithLocalChanges (Raw) (Key) (Value)
end =
functor
  (Raw : Raw)
  (Key : Key)
  (Value : Value.Type)
  ->
  struct
    module WithLocalChanges = WithLocalChanges (Raw) (Key) (Value)

    let add key value = WithLocalChanges.add (Key.md5 key) value

    let mem key = WithLocalChanges.mem (Key.md5 key)

    let get key =
      let key = Key.md5 key in
      if WithLocalChanges.mem key then
        Some (WithLocalChanges.get key)
      else
        None

    let find_unsafe key =
      match get key with
      | None -> raise Caml.Not_found
      | Some x -> x

    let remove key =
      let key = Key.md5 key in
      if WithLocalChanges.mem key then (
        WithLocalChanges.remove key;
        assert (not (WithLocalChanges.mem key))
      ) else
        ()

    let oldify key =
      if mem key then
        let old_key = Key.to_old key in
        WithLocalChanges.move (Key.md5 key) (Key.md5_old old_key)
      else
        ()
  end

(* Same as new, but for old values *)
module Old : functor
  (Raw : Raw)
  (Key : Key)
  (Value : Value.Type)
  (WithLocalChanges : module type of WithLocalChanges (Raw) (Key) (Value))
  -> sig
  val get : Key.old -> Value.t option

  val remove : Key.old -> unit

  val mem : Key.old -> bool

  (* Takes an old value and moves it back to a "new" one *)
  val revive : Key.old -> unit
end =
functor
  (Raw : Raw)
  (Key : Key)
  (Value : Value.Type)
  (WithLocalChanges : module type of WithLocalChanges (Raw) (Key) (Value))
  ->
  struct
    let get key =
      let key = Key.md5_old key in
      if WithLocalChanges.mem key then
        Some (WithLocalChanges.get key)
      else
        None

    let mem key = WithLocalChanges.mem (Key.md5_old key)

    let remove key = if mem key then WithLocalChanges.remove (Key.md5_old key)

    let revive key =
      if mem key then (
        let new_key = Key.new_from_old key in
        let new_key = Key.md5 new_key in
        let old_key = Key.md5_old key in
        if WithLocalChanges.mem new_key then WithLocalChanges.remove new_key;
        WithLocalChanges.move old_key new_key
      )
  end

(*****************************************************************************)
(* The signatures of what we are actually going to expose to the user *)
(*****************************************************************************)

module type NoCache = sig
  type key

  type t

  module KeySet : Set.S with type elt = key

  module KeyMap : WrappedMap.S with type key = key

  val add : key -> t -> unit

  val get : key -> t option

  val get_old : key -> t option

  val get_old_batch : KeySet.t -> t option KeyMap.t

  val remove_old_batch : KeySet.t -> unit

  val find_unsafe : key -> t

  val get_batch : KeySet.t -> t option KeyMap.t

  val remove_batch : KeySet.t -> unit

  val string_of_key : key -> string

  val mem : key -> bool

  val mem_old : key -> bool

  val oldify_batch : KeySet.t -> unit

  val revive_batch : KeySet.t -> unit

  module LocalChanges : sig
    val has_local_changes : unit -> bool

    val push_stack : unit -> unit

    val pop_stack : unit -> unit

    val revert_batch : KeySet.t -> unit

    val commit_batch : KeySet.t -> unit

    val revert_all : unit -> unit

    val commit_all : unit -> unit
  end
end

module type WithCache = sig
  include NoCache

  val write_around : key -> t -> unit

  val get_no_cache : key -> t option
end

(*****************************************************************************)
(* The interface that all keys need to implement *)
(*****************************************************************************)

module type UserKeyType = sig
  type t

  val to_string : t -> string

  val compare : t -> t -> int
end

(*****************************************************************************)
(* A functor returning an implementation of the S module without caching. *)
(*****************************************************************************)

module NoCache (Raw : Raw) (UserKeyType : UserKeyType) (Value : Value.Type) =
struct
  module Key = KeyFunctor (UserKeyType)
  module New = New (Raw) (Key) (Value)
  module Old = Old (Raw) (Key) (Value) (New.WithLocalChanges)
  module KeySet = Set.Make (UserKeyType)
  module KeyMap = WrappedMap.Make (UserKeyType)

  type key = UserKeyType.t

  type t = Value.t

  let string_of_key key =
    key |> Key.make Value.prefix |> Key.md5 |> Key.string_of_md5

  let add x y = New.add (Key.make Value.prefix x) y

  let find_unsafe x = New.find_unsafe (Key.make Value.prefix x)

  let get x = New.get (Key.make Value.prefix x)

  let get_old x =
    let key = Key.make_old Value.prefix x in
    Old.get key

  let get_old_batch xs =
    KeySet.fold
      begin
        fun str_key acc ->
        let key = Key.make_old Value.prefix str_key in
        KeyMap.add str_key (Old.get key) acc
      end
      xs
      KeyMap.empty

  let remove_batch xs =
    KeySet.iter
      begin
        fun str_key ->
        let key = Key.make Value.prefix str_key in
        New.remove key
      end
      xs

  let oldify_batch xs =
    KeySet.iter
      begin
        fun str_key ->
        let key = Key.make Value.prefix str_key in
        if New.mem key then
          New.oldify key
        else
          let key = Key.make_old Value.prefix str_key in
          Old.remove key
      end
      xs

  let revive_batch xs =
    KeySet.iter
      begin
        fun str_key ->
        let old_key = Key.make_old Value.prefix str_key in
        if Old.mem old_key then
          Old.revive old_key
        else
          let key = Key.make Value.prefix str_key in
          New.remove key
      end
      xs

  let get_batch xs =
    KeySet.fold
      begin
        fun str_key acc ->
        let key = Key.make Value.prefix str_key in
        match New.get key with
        | None -> KeyMap.add str_key None acc
        | Some data -> KeyMap.add str_key (Some data) acc
      end
      xs
      KeyMap.empty

  let mem x = New.mem (Key.make Value.prefix x)

  let mem_old x = Old.mem (Key.make_old Value.prefix x)

  let remove_old_batch xs =
    KeySet.iter
      begin
        fun str_key ->
        let key = Key.make_old Value.prefix str_key in
        Old.remove key
      end
      xs

  module LocalChanges = struct
    include New.WithLocalChanges.LocalChanges

    let revert_batch keys =
      KeySet.iter
        begin
          fun str_key ->
          let key = Key.make Value.prefix str_key in
          revert (Key.md5 key)
        end
        keys

    let commit_batch keys =
      KeySet.iter
        begin
          fun str_key ->
          let key = Key.make Value.prefix str_key in
          commit (Key.md5 key)
        end
        keys
  end
end

(*****************************************************************************)
(* All the caches are functors returning a module of the following signature
 *)
(*****************************************************************************)

module type CacheType = sig
  type key

  type value

  val add : key -> value -> unit

  val get : key -> value option

  val remove : key -> unit

  val clear : unit -> unit

  val string_of_key : key -> string

  val get_size : unit -> int

  val get_telemetry_items_and_keys : unit -> Obj.t * key Seq.t
end

(*****************************************************************************)
(* FreqCache and OrderedCache are both local Hashtbl.t-based caches of       *)
(* bounded size in the ocaml heap, design to be used together.               *)
(*                                                                           *)
(* - FreqCache is an LFU cache - "Least Frequently Used" - which keeps count *)
(* of how many times each item in the cache has been added/replaced/fetched  *)
(* and, when it reaches 2*capacity, then it flushes 1*capacity items and     *)
(* they lose their counts. This might result in a lucky few early items      *)
(* getting to stay in the cache while newcomers get evicted...               *)
(*                                                                           *)
(* - OrderedCache is a LRA cache - "Least Recently Added" - which, whenever  *)
(* you add an item beyond capacity, will evict the oldest one to be added.   *)
(*                                                                           *)
(* If you keep both kinds of caches simultaneously, and add items to both    *)
(* of them, then hopefully each one will paper over the other's weaknesses.  *)
(*****************************************************************************)

module type LocalHashtblConfigType = sig
  (* The type of object we want to keep in cache *)
  type value

  (* The capacity of the cache *)
  val capacity : int
end

module FreqCache (Key : sig
  type t
end)
(LocalHashtblConfig : LocalHashtblConfigType) :
  CacheType with type key := Key.t and type value := LocalHashtblConfig.value =
struct
  type value = LocalHashtblConfig.value

  let string_of_key _key = failwith "FreqCache does not support 'string_of_key'"

  (* The cache itself *)
  let (cache : (Key.t, int ref * value) Hashtbl.t) =
    Hashtbl.create (2 * LocalHashtblConfig.capacity)

  let size = ref 0

  let get_size () = !size

  let get_telemetry_items_and_keys () =
    (Obj.repr cache, Hashtbl.to_seq_keys cache)

  let clear () =
    Hashtbl.clear cache;
    size := 0

  (* The collection function is called when we reach twice original
   * capacity in size. When the collection is triggered, we only keep
   * the most frequently used objects.
   * So before collection: size = 2 * capacity
   * After collection: size = capacity (with the most frequently used objects)
   *)
  let collect () =
    if !size < 2 * LocalHashtblConfig.capacity then
      ()
    else
      let l = ref [] in
      Hashtbl.iter
        begin
          fun key (freq, v) ->
          l := (key, !freq, v) :: !l
        end
        cache;
      Hashtbl.clear cache;
      l := List.sort ~compare:(fun (_, x, _) (_, y, _) -> y - x) !l;
      let i = ref 0 in
      while !i < LocalHashtblConfig.capacity do
        match !l with
        | [] -> i := LocalHashtblConfig.capacity
        | (k, _freq, v) :: rl ->
          Hashtbl.replace cache k (ref 0, v);
          l := rl;
          incr i
      done;
      size := LocalHashtblConfig.capacity;
      ()

  let add x y =
    collect ();
    match Hashtbl.find_opt cache x with
    | Some (freq, y') ->
      incr freq;
      if phys_equal y' y then
        ()
      else
        Hashtbl.replace cache x (freq, y)
    | None ->
      incr size;
      let elt = (ref 0, y) in
      Hashtbl.replace cache x elt;
      ()

  let get x =
    match Hashtbl.find_opt cache x with
    | None -> None
    | Some (freq, value) ->
      incr freq;
      Some value

  let remove x =
    if Hashtbl.mem cache x then decr size;
    Hashtbl.remove cache x
end

module OrderedCache (Key : sig
  type t
end)
(LocalHashtblConfig : LocalHashtblConfigType) :
  CacheType with type key := Key.t and type value := LocalHashtblConfig.value =
struct
  let string_of_key _key =
    failwith "OrderedCache does not support 'string_of_key'"

  let (cache : (Key.t, LocalHashtblConfig.value) Hashtbl.t) =
    Hashtbl.create LocalHashtblConfig.capacity

  let queue = Queue.create ()

  let size = ref 0

  let get_size () = !size

  let get_telemetry_items_and_keys () =
    (Obj.repr cache, Hashtbl.to_seq_keys cache)

  let clear () =
    Hashtbl.clear cache;
    size := 0;
    Queue.clear queue;
    ()

  let add x y =
    ( if !size >= LocalHashtblConfig.capacity then
      (* Remove oldest element - if it's still around. *)
      let elt = Queue.pop queue in
      if Hashtbl.mem cache elt then (
        decr size;
        Hashtbl.remove cache elt
      ) );

    (* Add the new element, but bump the size only if it's a new addition. *)
    Queue.push x queue;
    if not (Hashtbl.mem cache x) then incr size;
    Hashtbl.replace cache x y

  let get x = Hashtbl.find_opt cache x

  let remove x =
    if Hashtbl.mem cache x then begin
      decr size;
      Hashtbl.remove cache x
    end
end

(*****************************************************************************)
(* Every time we create a new cache, a function that knows how to clear the
 * cache is registered in the "invalidate_callback_list" global.
 *)
(*****************************************************************************)

let invalidate_callback_list = ref []

let invalidate_caches () =
  List.iter !invalidate_callback_list (fun callback -> callback ())

module LocalCache
    (UserKeyType : UserKeyType)
    (Value : Value.Type)
    (Capacity : LocalCapacityType) =
struct
  type key = UserKeyType.t

  type value = Value.t

  module LocalHashtblConfig = struct
    type value = Value.t

    let capacity = Capacity.capacity
  end

  (* Young values cache *)
  module L1 = OrderedCache (UserKeyType) (LocalHashtblConfig)

  (* Frequent values cache *)
  module L2 = FreqCache (UserKeyType) (LocalHashtblConfig)
  module KeySet = Set.Make (UserKeyType)

  let string_of_key _key =
    failwith "LocalCache does not support 'string_of_key'"

  let add x y =
    L1.add x y;
    L2.add x y

  let get x =
    match L1.get x with
    | None ->
      (match L2.get x with
      | None -> None
      | Some v as result ->
        L1.add x v;
        result)
    | Some v as result ->
      L2.add x v;
      result

  let remove x =
    L1.remove x;
    L2.remove x

  let clear () =
    L1.clear ();
    L2.clear ()

  let get_telemetry (telemetry : Telemetry.t) : Telemetry.t =
    (* Many items are stored in both L1 (ordered) and L2 (freq) caches.
    We don't want to double-count them.
    So: we'll figure out the reachable words of the (L1,L2) tuple,
    and we'll figure out the set union of keys in both of them. *)
    let (obj1, keys1) = L1.get_telemetry_items_and_keys () in
    let (obj2, keys2) = L2.get_telemetry_items_and_keys () in
    let count =
      KeySet.empty
      |> KeySet.add_seq keys1
      |> KeySet.add_seq keys2
      |> KeySet.cardinal
    in
    if count = 0 then
      telemetry
    else
      let bytes =
        if hh_log_level () > 0 then
          Some (Obj.reachable_words (Obj.repr (obj1, obj2)) * Sys.word_size / 8)
        else
          None
      in
      telemetry
      |> Telemetry.object_
           ~key:(Value.description ^ "__local")
           ~value:
             ( Telemetry.create ()
             |> Telemetry.int_ ~key:"count" ~value:count
             |> Telemetry.int_opt ~key:"bytes" ~value:bytes )

  let () =
    get_telemetry_list := get_telemetry :: !get_telemetry_list;
    invalidate_callback_list :=
      begin
        fun () ->
        L1.clear ();
        L2.clear ()
      end
      :: !invalidate_callback_list
end

(*****************************************************************************)
(* A functor returning an implementation of the S module with caching.
 * We need to avoid constantly deserializing types, because it costs us too
 * much time. The caches keep a deserialized version of the types.
 *)
(*****************************************************************************)
module WithCache
    (Raw : Raw)
    (UserKeyType : UserKeyType)
    (Value : Value.Type)
    (Capacity : LocalCapacityType) =
struct
  module ValueForCache = struct
    include Value

    let description = Value.description ^ "__cache"
  end

  module Direct = NoCache (Raw) (UserKeyType) (Value)

  type key = Direct.key

  type t = Direct.t

  module KeySet = Direct.KeySet
  module KeyMap = Direct.KeyMap
  module Cache = LocalCache (UserKeyType) (ValueForCache) (Capacity)

  let string_of_key key = Direct.string_of_key key

  let add x y =
    Direct.add x y;
    Cache.add x y

  let get_no_cache = Direct.get

  let write_around x y =
    (* Note that we do not need to do any cache invalidation here because
     * Direct.add is a no-op if the key already exists. *)
    Direct.add x y

  let log_hit_rate ~hit =
    Measure.sample
      (Value.description ^ " (cache hit rate)")
      ( if hit then
        1.
      else
        0. );
    Measure.sample
      "(ALL cache hit rate)"
      ( if hit then
        1.
      else
        0. )

  let get x =
    match Cache.get x with
    | None ->
      let result =
        match Direct.get x with
        | None -> None
        | Some v as result ->
          Cache.add x v;
          result
      in
      if hh_log_level () > 0 then log_hit_rate ~hit:false;
      result
    | Some _ as result ->
      if hh_log_level () > 0 then log_hit_rate ~hit:true;
      result

  (* We don't cache old objects, they are not accessed often enough. *)
  let get_old = Direct.get_old

  let get_old_batch = Direct.get_old_batch

  let mem_old = Direct.mem_old

  let find_unsafe x =
    match get x with
    | None -> raise Caml.Not_found
    | Some x -> x

  let mem x =
    match get x with
    | None -> false
    | Some _ -> true

  let get_batch keys =
    KeySet.fold
      begin
        fun key acc ->
        KeyMap.add key (get key) acc
      end
      keys
      KeyMap.empty

  let oldify_batch keys =
    Direct.oldify_batch keys;
    KeySet.iter Cache.remove keys

  let revive_batch keys =
    Direct.revive_batch keys;
    KeySet.iter Cache.remove keys

  let remove_batch xs =
    Direct.remove_batch xs;
    KeySet.iter Cache.remove xs

  let () =
    invalidate_callback_list :=
      begin
        fun () ->
        Cache.clear ()
      end
      :: !invalidate_callback_list

  let remove_old_batch = Direct.remove_old_batch

  module LocalChanges = struct
    let push_stack () =
      Direct.LocalChanges.push_stack ();
      Cache.clear ()

    let pop_stack () =
      Direct.LocalChanges.pop_stack ();
      Cache.clear ()

    let revert_batch keys =
      Direct.LocalChanges.revert_batch keys;
      KeySet.iter Cache.remove keys

    let commit_batch keys =
      Direct.LocalChanges.commit_batch keys;
      KeySet.iter Cache.remove keys

    let revert_all () =
      Direct.LocalChanges.revert_all ();
      Cache.clear ()

    let commit_all () =
      Direct.LocalChanges.commit_all ();
      Cache.clear ()

    let has_local_changes () = Direct.LocalChanges.has_local_changes ()
  end
end
