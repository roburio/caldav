
module Fs = Mirage_fs_mem

type t = Fs.t

type file = [ `File of string list ]

type dir = [ `Dir of string list ]

type file_or_dir = [ file | dir ]

val create_file : dir -> string -> file

val dir_from_string : string -> dir

val file_from_string : string -> file

val from_string : t -> string -> (file_or_dir, Fs.error) result Lwt.t

val to_string : file_or_dir -> string

type propmap = (Webdav_xml.attribute list * Webdav_xml.tree list) Webdav_xml.PairMap.t

val get_property_map : t -> file_or_dir -> propmap option Lwt.t

val write_property_map : t -> file_or_dir -> propmap ->
  (unit, Fs.write_error) result Lwt.t

val size : t -> file -> (int64, Fs.error) result Lwt.t

val read : t -> file -> (Cstruct.t * propmap, Fs.error) result Lwt.t

val stat : t -> file_or_dir -> (Mirage_fs.stat, Fs.error) result Lwt.t

val exists : t -> string -> bool Lwt.t

val listdir : t -> dir -> (file_or_dir list, Fs.error) result Lwt.t

val last_modified : t -> file_or_dir ->
  (string, [ Fs.error | `Invalid_xml | `Invalid_date | `Unknown_prop ]) result Lwt.t

val mkdir : t -> dir -> propmap -> (unit, Fs.write_error) result Lwt.t

val write : t -> file -> Cstruct.t -> propmap -> (unit, Fs.write_error) result Lwt.t

val destroy : t -> file_or_dir -> (unit, Fs.write_error) result Lwt.t

val pp_error : Fs.error Fmt.t

val pp_write_error : Fs.write_error Fmt.t

val connect : unit -> t Lwt.t