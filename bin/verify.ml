open Common

let src = Logs.Src.create "mti-gf.verify" ~doc:"logs mti-gf's verify event"
module Log = (val Logs.src_log src : Logs.LOG)

let in_channel_of_message maildir message =
  let m = Maildir.to_fpath maildir message in
  if Sys.file_exists (Fpath.to_string m)
  then if not (Sys.is_directory (Fpath.to_string m))
    then Rresult.R.ok (open_in (Fpath.to_string m))
    else Rresult.R.error_msgf "%a is a directory, expected a file." Fpath.pp m
  else Rresult.R.error_msgf "%a does not exists" Fpath.pp m

let parse_in_channel new_line ic =
  let open Angstrom.Buffered in
  let raw = Bytes.create 4096 in
  let rec go = function
    | Partial continue ->
      let len = input ic raw 0 (Bytes.length raw) in
      let raw = sanitize_input new_line raw len in
      let res = if len = 0 then continue `Eof else continue (`String raw) in
      go res
    | Done (_, _) -> close_in ic ; Ok ()
    | Fail (_, _, err) -> close_in ic ; Error (`Msg err) in
  go (parse Mrmime.Mail.mail)

module Status = struct
  let ok = Fmt.const Fmt.string "[OK]" |> Fmt.styled `Green
  let error = Fmt.const Fmt.string "[ERROR]" |> Fmt.styled `Red
  let wait = Fmt.const Fmt.string "[...]" |> Fmt.styled `Yellow
end

let just_verify maildir new_line message =
  let open Rresult.R in
  Fmt.pr "%a %a.%!" Status.wait () Maildir.pp_message message ;
  in_channel_of_message maildir message >>= fun ic ->
  parse_in_channel new_line ic |> function
  | Ok _ as v ->
    Fmt.pr "\r%a %a.\n%!" Status.ok () Maildir.pp_message message ; v
  | Error (`Msg err) ->
    Fmt.pr "\r%a %a: %s.\n%!" Status.error () Maildir.pp_message message err ;
    error_msgf "On %a: %s" Maildir.pp_message message err

let run () maildir_path host verify_only_new_messages new_line =
  let maildir = Maildir.create ~pid:(Unix.getpid ()) ~host ~random maildir_path in

  match Maildir_unix.(verify fs maildir) with
  | false ->
    Fmt.pr "%a Invalid Maildir directory.\n%!" Status.error () ;
    Rresult.R.error_msgf "%a is not a valid Maildir directory." Fpath.pp maildir_path
  | true ->
    let cons =
      if verify_only_new_messages
      then (fun a x -> if Maildir.is_new x then x :: a else a)
      else (fun a x -> x :: a) in
    let to_verify = Maildir_unix.(fold cons [] fs maildir) in
    List.map (just_verify maildir new_line) to_verify
    |> List.filter (function Error _ -> true | _ -> false)
    |> List.map (function Error err -> err | _ -> assert false)
    |> function
    | [] -> Rresult.R.ok ()
    | [ `Msg err ] -> Rresult.R.error_msg err
    | errors ->
      List.iter (fun (`Msg err) -> Log.err @@ fun m -> m "Retrieve an error: %s." err) errors ;
      Rresult.R.error (`Some errors)

open Cmdliner

let maildir_path =
  let doc = "Path of <maildir> directory." in
  Arg.(required & opt (some Conv.existing_directory) None & info [ "m"; "maildir" ] ~docv:"<maildir>" ~doc)

let host =
  let doc = "Hostname of machine." in
  Arg.(value & opt Conv.hostname (Unix.gethostname ()) & info [ "h"; "host" ] ~docv:"<host>" ~doc)

let verify =
  let doc = "Verify only new messages." in
  Arg.(value & flag & info [ "only-new" ] ~doc)

let command =
  let doc = "Verify tool." in
  let exits = Term.default_exits in
  let man =
    [ `S Manpage.s_description
    ; `P "Verify mails from a <maildir> directory." ] in
  Term.(pure run $ Arguments.setup_fmt_and_logs $ maildir_path $ host $ verify $ Arguments.new_line),
  Term.info "verify" ~doc ~exits ~man
