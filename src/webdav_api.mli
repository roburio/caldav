
type state = Webdav_fs.Fs.t

val dav_ns : Tyxml.Xml.attrib

val mkcol : ?now:Ptime.t -> state -> string -> Webdav_xml.tree option ->
  (state, [ `Bad_request | `Conflict | `Forbidden of Webdav_xml.tree ])
    result Lwt.t

val propfind : state -> prefix:string -> name:string -> body:string -> depth:string option ->
  (state * string, [ `Bad_request | `Forbidden of string | `Property_not_found ]) result Lwt.t

val proppatch : state -> prefix:string -> name:string -> body:string ->
  (state * string, [ `Bad_request ]) result Lwt.t

(*
val delete : state -> string -> state

val get : state -> string ->

val head : state -> string ->

val post : state -> string -> ?? -> state

val put : state -> string ->

val read : state -> string ->

val write : state -> string ->
*)
