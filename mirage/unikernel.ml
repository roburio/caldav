open Lwt.Infix

let server_src = Logs.Src.create "http.server" ~doc:"HTTP server"
module Server_log = (val Logs.src_log server_src : Logs.LOG)

let access_src = Logs.Src.create "http.access" ~doc:"HTTP server access log"
module Access_log = (val Logs.src_log access_src : Logs.LOG)

module Main (C : Mirage_console.S) (R : Mirage_random.S) (T : Mirage_time.S) (Clock: Mirage_clock.PCLOCK) (Stack : Mirage_stack.V4V6) (_ : sig end) (S: Cohttp_mirage.Server.S) (Zap : Mirage_kv.RO) (Management : Mirage_stack.V4V6) = struct
  module Store = Irmin_mirage_git.KV_RW(Irmin_git.Mem)(Clock)
  module Dav_fs = Caldav.Webdav_fs.Make(Clock)(Store)
  module Dav = Caldav.Webdav_api.Make(R)(Clock)(Dav_fs)
  module Webdav_server = Caldav.Webdav_server.Make(R)(Clock)(Dav_fs)(S)
  module Dns = Dns_certify_mirage.Make(R)(Clock)(T)(Stack)

  (* Redirect to the same address, but in https. *)
  let redirect port request _body =
    let redirect_port = match port with 443 -> None | x -> Some x in
    let uri = Cohttp.Request.uri request in
    let new_uri = Uri.with_scheme uri (Some "https") in
    let new_uri = Uri.with_port new_uri redirect_port in
    Access_log.debug (fun f -> f "[%s] -> [%s]"
                         (Uri.to_string uri) (Uri.to_string new_uri));
    let headers = Cohttp.Header.init_with "location" (Uri.to_string new_uri) in
    S.respond ~headers ~status:`Moved_permanently ~body:`Empty ()

  let opt_static_file zap_data next request body =
    let uri = Cohttp.Request.uri request in
    let path = match Uri.path uri with
      | "/" -> "/index.html"
      | p -> p
    in
    Zap.get zap_data (Mirage_kv.Key.v path) >>= function
    | Ok data ->
      let mime_type = Magic_mime.lookup path in
      let headers = Cohttp.Header.init_with "content-type" mime_type in
      S.respond ~headers ~status:`OK ~body:(`String data) ()
    | _ -> next request body

  let get_user_from_auth = function
    | None -> None
    | Some v -> match Astring.String.cut ~sep:"Basic " v with
      | Some ("", b64) ->
        begin match Base64.decode b64 with
          | Error _ -> Some "bad b64 encoding"
          | Ok data -> match Astring.String.cut ~sep:":" data with
            | Some (user, _) -> Some user
            | None -> Some "no : between user and password"
        end
      | _ -> Some "not basic"

  let serve (author_k, user_agent_k, request_k) callback =
    let callback (_, cid) request body =
      let open Cohttp in
      let cid = Connection.to_string cid in
      let uri = Request.uri request in
      Access_log.debug (fun f -> f "[%s] serving %s." cid (Uri.to_string uri));
      let hdr = request.Request.headers in
      Lwt.with_value author_k (get_user_from_auth (Header.get hdr "Authorization")) @@ fun () ->
      Lwt.with_value user_agent_k (Header.get hdr "User-Agent") @@ fun () ->
      let req = Fmt.strf "%s %s" (Code.string_of_method request.Request.meth) (Uri.path uri) in
      Lwt.with_value request_k (Some req) @@ fun () ->
      callback request body
    and conn_closed (_,cid) =
      let cid = Cohttp.Connection.to_string cid in
      Access_log.debug (fun f -> f "[%s] closing" cid);
    in
    S.make ~conn_closed ~callback ()

  module Monitoring = Monitoring_experiments.Make(T)(Management)
  module Syslog = Logs_syslog_mirage.Udp(C)(Clock)(Management)

  let start c _random _time _clock stack ctx http zap management =
    let hostname = Key_gen.name ()
    and syslog = Key_gen.syslog ()
    and monitor = Key_gen.monitor ()
    in
    (match syslog with
     | None -> Logs.warn (fun m -> m "no syslog specified, dumping on stdout")
     | Some ip -> Logs.set_reporter (Syslog.create c management ip ~hostname ()));
    (match monitor with
     | None -> Logs.warn (fun m -> m "no monitor specified, not outputting statistics")
     | Some ip -> Monitoring.create ~hostname ip management);
    let author = Lwt.new_key ()
    and user_agent = Lwt.new_key ()
    and http_req = Lwt.new_key ()
    in
    let dynamic = author, user_agent, http_req in
    let init_http port config store =
      Server_log.info (fun f -> f "listening on %d/HTTP" port);
      http (`TCP port) @@ serve dynamic @@ opt_static_file zap @@ Webdav_server.dispatch config store
    in
    let init_https port config store =
      let hostname = Domain_name.(host_exn (of_string_exn hostname)) in
      Dns.retrieve_certificate
        stack ~dns_key:(Key_gen.dns_key ())
        ~hostname ~key_seed:(Key_gen.key_seed ())
        (Key_gen.dns_server ()) (Key_gen.dns_port ()) >>= function
      | Error (`Msg m) -> Lwt.fail_with m
      | Ok certificates ->
        let certificates = `Single certificates in
        let tls_config = Tls.Config.server ~certificates () in
        Server_log.info (fun f -> f "listening on %d/HTTPS" port);
        let tls = `TLS (tls_config, `TCP port) in
        http tls @@ serve dynamic @@ opt_static_file zap @@  Webdav_server.dispatch config store
    in
    let config host =
      let do_trust_on_first_use = Key_gen.tofu () in
      Caldav.Webdav_config.config ~do_trust_on_first_use host
    in
    let init_store_for_runtime config =
      let admin_pass = Key_gen.admin_password () in
      Irmin_git.Mem.v (Fpath.v "bla") >>= function
      | Error _ -> assert false
      | Ok git ->
        (* TODO maybe source IP address? turns out to be not trivial
                (unclear how to get it from http/conduit) *)
        let author () =
          Fmt.strf "%a (via caldav)"
            Fmt.(option ~none:(unit "no author") string) (Lwt.get author)
        and msg op =
          let op_str = function
            | `Set k -> Fmt.strf "updating %a" Mirage_kv.Key.pp k
            | `Remove k -> Fmt.strf "removing %a" Mirage_kv.Key.pp k
            | `Batch -> "batch operation"
          in
          Fmt.strf "calendar change %s@.during processing HTTP request %a@.by user-agent %a"
            (op_str op)
            Fmt.(option ~none:(unit "no HTTP request") string) (Lwt.get http_req)
            Fmt.(option ~none:(unit "none") string) (Lwt.get user_agent)
        in
        Store.connect git ~depth:1 ~ctx ~author ~msg (Key_gen.remote ()) >>= fun store ->
        Dav.connect store config admin_pass
    in
    match Key_gen.http_port (), Key_gen.https_port () with
    | None, None ->
      Logs.err (fun m -> m "no port provided for neither HTTP nor HTTPS, exiting") ;
      Lwt.return_unit
    | Some port, None ->
      let config = config @@ Caldav.Webdav_config.host ~port ~hostname () in
      init_store_for_runtime config >>=
      init_http port config
    | None, Some port ->
      let config = config @@ Caldav.Webdav_config.host ~scheme:"https" ~port ~hostname () in
      init_store_for_runtime config >>=
      init_https port config
    | Some http_port, Some https_port ->
      Server_log.info (fun f -> f "redirecting on %d/HTTP to %d/HTTPS" http_port https_port);
      let config = config @@ Caldav.Webdav_config.host ~scheme:"https" ~port:https_port ~hostname () in
      init_store_for_runtime config >>= fun store ->
      Lwt.pick [
        http (`TCP http_port) @@ serve dynamic (redirect https_port) ;
        init_https https_port config store
      ]
end
