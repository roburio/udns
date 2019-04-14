(* (c) 2017, 2018 Hannes Mehnert, all rights reserved *)

open Udns

type rank =
  | ZoneFile
  | ZoneTransfer
  | AuthoritativeAnswer
  | AuthoritativeAuthority
  | ZoneGlue
  | NonAuthoritativeAnswer
  | Additional

let compare_rank a b = match a, b with
  | ZoneFile, ZoneFile -> `Equal
  | ZoneFile, _ -> `Bigger
  | _, ZoneFile -> `Smaller
  | ZoneTransfer, ZoneTransfer -> `Equal
  | ZoneTransfer, _ -> `Bigger
  | _, ZoneTransfer -> `Smaller
  | AuthoritativeAnswer, AuthoritativeAnswer -> `Equal
  | AuthoritativeAnswer, _ -> `Bigger
  | _, AuthoritativeAnswer -> `Smaller
  | AuthoritativeAuthority, AuthoritativeAuthority -> `Equal
  | AuthoritativeAuthority, _ -> `Bigger
  | _, AuthoritativeAuthority -> `Smaller
  | ZoneGlue, ZoneGlue -> `Equal
  | ZoneGlue, _ -> `Bigger
  | _, ZoneGlue -> `Smaller
  | NonAuthoritativeAnswer, NonAuthoritativeAnswer -> `Equal
  | NonAuthoritativeAnswer, _ -> `Bigger
  | _, NonAuthoritativeAnswer -> `Smaller
  | Additional, Additional -> `Equal

let pp_ord ppf = function
  | `Bigger -> Fmt.string ppf "bigger"
  | `Smaller -> Fmt.string ppf "smaller"
  | `Equal -> Fmt.string ppf "equal"

let pp_rank ppf r = Fmt.string ppf (match r with
    | ZoneFile -> "zone file data"
    | ZoneTransfer -> "zone transfer data"
    | AuthoritativeAnswer -> "authoritative answer data"
    | AuthoritativeAuthority -> "authoritative authority data"
    | ZoneGlue -> "zone file glue"
    | NonAuthoritativeAnswer -> "non-authoritative answer"
    | Additional -> "additional data")

module RRMap = Map.Make(Rr)

module V = struct
  type meta = int64 * rank
  let pp_meta ppf (crea, rank) =
    Fmt.pf ppf "%a created %Lu" pp_rank rank crea

  type rr_map_entry =
    | Entry of Rr_map.b
    | No_data of Domain_name.t * Soa.t
    | Serv_fail of Domain_name.t * Soa.t
  let pp_map_entry ppf entry = match entry with
    | Entry b -> Fmt.pf ppf "entry %a" Rr_map.pp_b b
    | No_data (name, soa) -> Fmt.pf ppf "no data %a SOA %a" Domain_name.pp name Soa.pp soa
    | Serv_fail (name, soa) -> Fmt.pf ppf "server fail %a SOA %a" Domain_name.pp name Soa.pp soa
  let to_res = function
    | Entry b -> `Entry b
    | No_data (name, soa) -> `No_data (name, soa)
    | Serv_fail (name, soa) -> `Serv_fail (name, soa)
  let of_res = function
    | `Entry b -> Entry b
    | `No_data (name, soa) -> No_data (name, soa)
    | `Serv_fail (name, soa) -> Serv_fail (name, soa)
    | _ -> assert false

  type t =
    | Alias of meta * int32 * Domain_name.t
    | No_domain of meta * Domain_name.t * Soa.t
    | Rr_map of (meta * rr_map_entry) RRMap.t

  let weight = function
    | Alias _ | No_domain _ -> 1
    | Rr_map tm -> RRMap.cardinal tm

  let pp_entry ppf (meta, entry) = Fmt.pf ppf "e (%a) %a" pp_meta meta pp_map_entry entry

  let pp ppf = function
    | Alias (meta, ttl, a) ->
      Fmt.pf ppf "alias (%a) TTL %lu %a" pp_meta meta ttl Domain_name.pp a
    | No_domain (meta, name, soa) ->
      Fmt.pf ppf "no domain (%a) %a SOA %a" pp_meta meta Domain_name.pp name Soa.pp soa
    | Rr_map rr ->
      Fmt.pf ppf "entries: %a"
        Fmt.(list ~sep:(unit ";@,") (pair Rr.pp pp_entry))
        (RRMap.bindings rr)
end

module LRU = Lru.F.Make(Domain_name)(V)

type t = LRU.t

type stats = {
  hit : int ;
  miss : int ;
  drop : int ;
  insert : int ;
}

let s = ref { hit = 0 ; miss = 0 ; drop = 0 ; insert = 0 }

let pp_stats pf s =
  Fmt.pf pf "cache: %d hits %d misses %d drops %d inserts" s.hit s.miss s.drop s.insert

let stats () = !s

(* this could need a `Timeout error result *)

let empty = LRU.empty

let size = LRU.size

let capacity = LRU.capacity

let pp = LRU.pp Fmt.(pair ~sep:(unit ": ") Domain_name.pp V.pp)

module N = Domain_name.Set

let update_ttl ~created ~now ttl =
  Int32.sub ttl (Int32.of_int (Duration.to_sec (Int64.sub now created)))

type res = [
  | `Alias of int32 * Domain_name.t
  | `Entry of Rr_map.b
  | `No_data of Domain_name.t * Soa.t
  | `No_domain of Domain_name.t * Soa.t
  | `Serv_fail of Domain_name.t * Soa.t
]

let pp_res ppf res =
  let pp_ns ppf (name, soa) = Fmt.pf ppf "%a SOA %a" Domain_name.pp name Soa.pp soa in
  match res with
  | `Alias (ttl, name) -> Fmt.pf ppf "alias TTL %lu %a" ttl Domain_name.pp name
  | `Entry b -> Fmt.pf ppf "entry %a" Rr_map.pp_b b
  | `No_data ns -> Fmt.(prefix (unit "no data ") pp_ns) ppf ns
  | `No_domain ns -> Fmt.(prefix (unit "no domain ") pp_ns) ppf ns
  | `Serv_fail ns -> Fmt.(prefix (unit "serv fail ") pp_ns) ppf ns

let get_ttl = function
  | `Alias (ttl, _) -> ttl
  | `Entry b -> Rr_map.get_ttl b
  | `No_data (_, soa) -> soa.Soa.minimum
  | `No_domain (_, soa) -> soa.Soa.minimum
  | `Serv_fail (_, soa) -> soa.Soa.minimum

let with_ttl ttl = function
  | `Alias (_, name) -> `Alias (ttl, name)
  | `Entry b -> `Entry (Rr_map.with_ttl b ttl)
  | `No_data (name, soa) -> `No_data (name, { soa with Soa.minimum = ttl })
  | `No_domain (name, soa) -> `No_domain (name, { soa with Soa.minimum = ttl })
  | `Serv_fail (name, soa) -> `Serv_fail (name, { soa with Soa.minimum = ttl })

let find_lru t name typ =
  match LRU.find name t with
  | None -> None, Error `Cache_miss
  | Some Alias (meta, ttl, alias) -> None, Ok (meta, `Alias (ttl, alias))
  | Some No_domain (meta, name, soa) -> None, Ok (meta, `No_domain (name, soa))
  | Some Rr_map tm ->
    Some tm,
    try
      let meta, entry = RRMap.find typ tm in
      Ok (meta, V.to_res entry)
    with
    | Not_found -> Error `Cache_miss

let insert_lru t ?map name typ created rank res =
  s := { !s with insert = succ !s.insert };
  let meta = created, rank in
  let t' = match res with
    | `No_domain (name', soa) -> LRU.add name (No_domain (meta, name', soa)) t
    | `Alias (ttl, alias) -> LRU.add name (Alias (meta, ttl, alias)) t
    | `Entry _ | `No_data _ | `Serv_fail _ ->
      let map = match map with None -> RRMap.empty | Some x -> x in
      let map' = RRMap.add typ (meta, V.of_res res) map in
      LRU.add name (Rr_map map') t
  in
  LRU.trim t'

let cached_any rrmap now =
  let rrs =
    RRMap.fold (fun _typ ((created, _), e) acc ->
        match e with
        | V.No_data _ | V.Serv_fail _ -> acc
        | V.Entry b ->
          let ttl = Rr_map.get_ttl b in
          let updated_ttl = update_ttl ~created ~now ttl in
          if updated_ttl < 0l then acc
          else Rr_map.addb (Rr_map.with_ttl b updated_ttl) acc)
      rrmap Rr_map.empty
  in
  if Rr_map.is_empty rrs then
    Error `Cache_miss
  else
    Ok rrs

let cached t now typ nam =
  match find_lru t nam typ with
  | Some rrmap, _ when typ = Rr.ANY ->
    begin match cached_any rrmap now with
      | Error e ->
        s := { !s with miss = succ !s.miss };
        Error e
      | Ok map ->
        s := { !s with hit = succ !s.hit };
        Ok (`Entries map, LRU.promote nam t)
    end
  | _, Error e ->
    s := { !s with miss = succ !s.miss };
    Error e
  | _, Ok ((created, _), e) ->
    let ttl = get_ttl e in
    let updated_ttl = update_ttl ~created ~now ttl in
    if updated_ttl < 0l then begin
      s := { !s with drop = succ !s.drop };
      Error `Cache_drop
    end else begin
      s := { !s with hit = succ !s.hit };
      Ok (with_ttl updated_ttl e, LRU.promote nam t)
    end

let pp_err ppf = function
  | `Cache_drop -> Fmt.string ppf "cache drop"
  | `Cache_miss -> Fmt.string ppf "cache miss"

(* according to RFC1035, section 7.3, a TTL of a week is a good maximum value! *)
(* XXX: we may want to define a minimum as well (5 minutes? 30 minutes?
   use SOA expiry?) MS used to use 24 hours in internet explorer

from RFC1034 on this topic:
The idea is that if cached data is known to come from a particular zone,
and if an authoritative copy of the zone's SOA is obtained, and if the
zone's SERIAL has not changed since the data was cached, then the TTL of
the cached data can be reset to the zone MINIMUM value if it is smaller.
This usage is mentioned for planning purposes only, and is not
recommended as yet.

and 2308, Sec 4:
   Despite being the original defined meaning, the first of these, the
   minimum TTL value of all RRs in a zone, has never in practice been
   used and is hereby deprecated.

and 1035 6.2:
   The MINIMUM value in the SOA should be used to set a floor on the TTL of data
   distributed from a zone.  This floor function should be done when the data is
   copied into a response.  This will allow future dynamic update protocols to
   change the SOA MINIMUM field without ambiguous semantics.
*)
let week = Int32.of_int Duration.(to_sec (of_day 7))

let smooth_ttl e =
  let ttl = get_ttl e in
  if ttl < week then e else with_ttl week e

let maybe_insert typ nam ts rank e t =
  let entry = smooth_ttl e in
  match find_lru t nam typ with
  | map, Error _ ->
    Logs.debug (fun m -> m "maybe_insert: %a nothing found, adding: %a" Packet.Question.pp (nam, typ) pp_res entry);
    insert_lru ?map t nam typ ts rank entry
  | map, Ok ((_, rank'), entry) ->
    Logs.debug (fun m -> m "maybe_insert: %a found rank %a insert rank %a: %a (unless bigger)"
                   Packet.Question.pp (nam, typ) pp_rank rank' pp_rank rank pp_ord (compare_rank rank' rank));
    match compare_rank rank' rank with
    | `Bigger -> t
    | _ -> insert_lru ?map t nam typ ts rank entry

(*
let resolve_ns t ts name =
  match cached t ts Udns_enum.A name with
  | Error _ ->
    Logs.debug (fun m -> m "resolve_ns: error %a, need A" Domain_name.pp name);

    `NeedA name, t
  | Ok (`Entry Rr_map.(B (k, v) as b), t) ->
    begin
      match k, v with
      | Rr_map.A, (_, ips) ->
        Logs.debug (fun m -> m "resolve_ns: found a %a: %a)"
                       Domain_name.pp name Fmt.(list ~sep:(unit ", ") Ipaddr.V4.pp)
                       (Rr_map.Ipv4_set.elements ips));
        `HaveIPS ips, t
      | _ ->
        Logs.warn (fun m -> m "resolve_ns: ignoring %a (looked A %a)"
                      Rr_map.pp_b b Domain_name.pp name);
        `NeedA name, t
    end
  | Ok (`No_domain _, t) ->
    Logs.warn (fun m -> m "resolve_ns: NoDom cache lookup for %a"
                  Domain_name.pp name);
    `NoDom, t
  | Ok (`Alias (_, alias), t) ->
    Logs.warn (fun m -> m "resolve_ns: Alias cache lookup for %a: %a"
                  Domain_name.pp name Domain_name.pp alias );
    `NeedCname alias, t
  | Ok (`No_data _, t) ->
    Logs.warn (fun m -> m "resolve_ns: No data, cache lookup for %a"
                  Domain_name.pp name);
    `No, t
  | Ok (`Serv_fail _, t) ->
    Logs.warn (fun m -> m "resolve_ns: serv fail, cache lookup for %a"
                  Domain_name.pp name);
    `No, t
*)

(*
let find_ns t rng ts stash name =
  let pick = function
    | [] -> None
    | [ x ] -> Some x
    | xs -> Some (List.nth xs (Randomconv.int ~bound:(List.length xs) rng))
  in
  match cached t ts Udns_enum.NS name with
  | Error _ -> `NeedNS, t
  | Ok (NoErr Rr_map.(B (k, v) as b), t) ->
    (* TODO test case -- we can't pick right now, unfortunately
       the following setup is there in the wild:
       berliner-zeitung.de NS 1.ns.berlinonline.de, 2.ns.berlinonline.de, x.ns.berlinonline.de
       berlinonline.de NS 1.ns.berlinonline.net, 2.ns.berlinonline.net, dns-berlinonline-de.unbelievable-machine.net
       berlinonline.net NS 2.ns.berlinonline.de, x.ns.berlinonline.de, 1.ns.berlinonline.de.
       --> all delivered without glue *)
    begin match k, v with
      | Rr_map.Ns, (_, ns) ->
        begin
          let actual = Domain_name.Set.diff ns stash in
          match pick (Domain_name.Set.elements actual) with
          | None ->
            Logs.warn (fun m -> m "find_ns: couldn't take any name from %a (stash: %a), returning loop"
                          Fmt.(list ~sep:(unit ",@ ") Domain_name.pp) (Domain_name.Set.elements ns)
                          Fmt.(list ~sep:(unit ",@ ") Domain_name.pp) (Domain_name.Set.elements stash)) ;
            `Loop, t
          | Some nsname ->
            (* tricky conditional:
               foo.com NS ns1.foo.com ; ns1.foo.com CNAME ns1.bar.com (well, may not happen ;)
               foo.com NS ns1.foo.com -> NeedGlue foo.com *)
            match resolve_ns t ts nsname with
            | `NeedA aname, t when Domain_name.sub ~subdomain:aname ~domain:name -> `NeedGlue name, t
            | `NeedCname cname, t -> `NeedA cname, t
            | `HaveIPS ips, t ->
              (* TODO should use a non-empty list of ips here *)
              begin match pick (Rr_map.Ipv4_set.elements ips) with
                | None -> `NeedA nsname, t
                | Some ip -> `HaveIP ip, t
              end
            | `NeedA aname, t -> `NeedA aname, t
            | `No, t -> `No, t
            | `NoDom, t -> `NoDom, t
        end
      | Rr_map.Cname, (_, alias) -> `Cname alias, t (* foo.com CNAME bar.com case *)
      | _ ->
        Logs.err (fun m -> m "find_ns: looked for NS %a, but got %a"
                     Domain_name.pp name Rr_map.pp_b b) ;
        `No, t
    end
  | Ok (_, t) -> `No, t
*)

let find_nearest_ns rng ts t name =
  let pick = function
    | [] -> None
    | [ x ] -> Some x
    | xs -> Some (List.nth xs (Randomconv.int ~bound:(List.length xs) rng))
  in
  let find_ns name = match cached t ts Rr.NS name with
    | Ok (`Entry Rr_map.(B (Ns, (_, names))), _) -> Domain_name.Set.elements names
    | _ -> []
  and find_a name = match cached t ts Rr.A name with
    | Ok (`Entry Rr_map.(B (A, (_, ips))), _) -> Rr_map.Ipv4_set.elements ips
    | _ -> []
  in
  let rec go nam =
    match pick (find_ns nam) with
    | None -> go (Domain_name.drop_labels_exn nam)
    | Some ns -> match pick (find_a ns) with
      | None ->
        if Domain_name.sub ~subdomain:ns ~domain:nam then
          (* we actually need glue *)
          if Domain_name.(equal root nam) then begin
            Logs.err (fun m -> m "couldn't find root server"); assert false
          end else
            go (Domain_name.drop_labels_exn nam)
        else
          `NeedA ns
      | Some ip -> `HaveIP (nam, ip)
  in
  go name

(* below fails for cafe-blaumond.de, somewhere stuck in an zone hop:
    querying a.b.c.d.e.f, getting NS for d.e.f + A
     still no entry for e.f -> retrying same question all the time
  let rec go cur rest zone ip =
    (* if we find a NS, and an A record, go down *)
    (* if we find a NS, and no A record, needa *)
    (* if we get error, finish with what we have *)
    (* if we find nodom, nodata -> finish with what we have *)
    (* servfail returns an error *)
    Logs.debug (fun m -> m "nearest ns cur %a rest %a zone %a ip %a"
                   Domain_name.pp cur
                   Fmt.(list ~sep:(unit ".") string) rest
                   Domain_name.pp zone
                   Ipaddr.V4.pp_hum ip) ;
    match pick find_ns cur with
    | None -> `HaveIP (zone, ip)
    | Some ns -> begin match pick find_a ns with
      | None -> `NeedA ns
      | Some ip -> match rest with
        | [] -> `HaveIP (cur, ip)
        | hd::tl -> go (Domain_name.prepend_Exn cur hd) tl cur ip
        end
  in
  go Domain_name.root (List.rev (Domain_name.to_strings name)) Domain_name.root root
*)

let resolve t ~rng ts name typ =
  (* the standard recursive algorithm *)
  let rec go t typ name =
    Logs.debug (fun m -> m "go %a" Domain_name.pp name) ;
    match find_nearest_ns rng ts t name with
    | `NeedA ns -> go t Rr.A ns
    | `HaveIP (zone, ip) -> zone, name, typ, ip, t
  in
  go t typ name

(*
let _resolve t ~rng ts name typ =
  (* TODO return the bailiwick (zone the NS is responsible for) as well *)
  (* TODO this is the query name minimisation approach, reimplement the
          original recursive algorithm as well *)
  (* the top-to-bottom approach, for TYP a.b.c, lookup:
     @root NS, . -> A1
     @A1 NS, c -> A2
     @A2 NS, b.c -> A3
     @A3 NS. a.b.c -> NoData
     @A3 TYP, a.b.c -> A4

     where A{1-3} are all domain names, where we try to find A records (or hope
     to get them as glue)

     now, we have the issue of glue records: NS c (A2) will return names x.c
     and y.c, but also address records for them (otherwise there's no way to
     find out their addresses without knowing their addresses)

     A2 may as well contain a.c, b.c, and c.d - if delivered without glue, c.d
     is the only option to proceed (well, or ServFail or asking someone else for
     NS c) *)
  (* goal is to find the query to send out.
     we're applying qname minimisation on the way down

     it's a bit complicated, OTOH we're doing qname minimisation, but also may
     have to jump to other names (of NS or CNAME) - which is slightly intricate *)
  (* TODO this is misplaced, this should be properly handled by find_ns! *)
  let root =
    let roots = snd (List.split Udns_resolver_root.root_servers) in
    List.nth roots (Randomconv.int ~bound:(List.length roots) rng)
  in
  let rec go t stash typ cur rest zone ip =
    Logs.debug (fun m -> m "resolve entry: stash %a typ %a cur %a rest %a zone %a ip %a"
                   Fmt.(list ~sep:(unit ", ") Domain_name.pp) (N.elements stash)
                   Udns_enum.pp_rr_typ typ Domain_name.pp cur
                   Domain_name.pp (Domain_name.of_strings_exn ~hostname:false rest)
                   Domain_name.pp zone
                   Ipaddr.V4.pp ip) ;
    match find_ns t rng ts stash cur with
    | `NeedNS, t when Domain_name.equal cur Domain_name.root ->
      (* we don't have any root servers *)
      Ok (Domain_name.root, Domain_name.root, Udns_enum.NS, root, t)
    | `HaveIP ip, t ->
      Logs.debug (fun m -> m "resolve: have ip %a" Ipaddr.V4.pp ip) ;
      begin match rest with
        | [] -> Ok (zone, cur, typ, ip, t)
        | hd::tl -> go t stash typ (Domain_name.prepend_exn cur hd) tl zone ip
      end
    | `NeedNS, t ->
      Logs.debug (fun m -> m "resolve: needns") ;
      Ok (zone, cur, Udns_enum.NS, ip, t)
    | `Cname name, t ->
      (* NS name -> CNAME foo, only use foo if rest is empty *)
      Logs.debug (fun m -> m "resolve: cname %a" Domain_name.pp name) ;
      begin match rest with
        | [] ->
          let rest = List.rev (Domain_name.to_strings name) in
          go t (N.add name stash) typ Domain_name.root rest Domain_name.root root
        | hd::tl ->
          go t stash typ (Domain_name.prepend_exn cur hd) tl zone ip
      end
    | `NoDom, _ ->
      (* this is wrong for NS which NoDom for too much (even if its a ENT) *)
      Logs.debug (fun m -> m "resolve: nodom to %a!" Domain_name.pp cur) ;
      Error "can't resolve"
    | `No, _ ->
      Logs.debug (fun m -> m "resolve: no to %a!" Domain_name.pp cur) ;
      (* we tried to locate the NS for cur, but failed to find it *)
      (* it was ServFail/NoData in our cache.  how can we proceed? *)
      (* - ask the very same question to ips (NS / cur) - but we need to stop at some point *)
      (* - if rest = [], we just ask for cur+typ the ips --- this is common, e.g.
            ns1.foo.com NS @(foo.com authoritative)? - NoData, ns1.foo.com A @(foo.com authoritative) yay *)
      (* - if rest != [], (i.e. detectportal.firefox.com.edgesuite.net ->
               edgesuite.net -> NoData *)
      (* - give up!? *)
      (* this opens the door to amplification attacks :/ -- i.e. asking for
         a.b.c.d.e.f results in 6 requests (for f, e.f, d.e.f, c.d.e.f, b.c.d.e.f, a.b.c.d.e.f)  *)
      begin match rest with
        | [] -> Ok (zone, cur, typ, ip, t)
        | hd::tl -> go t stash typ (Domain_name.prepend_exn cur hd) tl zone ip
      end
    | `NeedGlue name, t ->
      Logs.debug (fun m -> m "resolve: needGlue %a" Domain_name.pp name) ;
      Ok (zone, name, Udns_enum.NS, ip, t)
    | `Loop, _ -> Error "resolve: cycle detected in find_ns"
    | `NeedA name, t ->
      Logs.debug (fun m -> m "resolve: needA %a" Domain_name.pp name) ;
      (* TODO: unclear whether this conditional is needed *)
      if N.mem name stash then begin
        Error "resolve: cycle detected during NeedA"
      end else
        let n = List.rev (Domain_name.to_strings name) in
        go t (N.add name stash) Udns_enum.A Domain_name.root n Domain_name.root root
  in
  go t (N.singleton name) typ Domain_name.root (List.rev (Domain_name.to_strings name)) Domain_name.root root
*)


let to_map (name, soa) =
  Domain_name.Map.singleton name Rr_map.(singleton Soa soa)

let follow_cname t ts typ ~name ttl ~alias =
  let rec follow t acc name =
    match cached t ts typ name with
    | Error _ ->
      Logs.debug (fun m -> m "follow_cname: cache miss, need to query %a"
                     Domain_name.pp name);
      `Query (name, t)
    | Ok (`Alias (ttl, alias), t) ->
      let acc' = Domain_name.Map.add name Rr_map.(singleton Cname (ttl, alias)) acc in
      if Domain_name.Map.mem alias acc then begin
        Logs.warn (fun m -> m "follow_cname: cycle detected") ;
        `Out (Rcode.NoError, acc', Name_rr_map.empty, t)
      end else begin
        Logs.debug (fun m -> m "follow_cname: alias to %a, follow again"
                       Domain_name.pp alias);
        follow t acc' alias
      end
    | Ok (`Entry (Rr_map.B (k, v)), t) ->
      let acc' = Domain_name.Map.add name Rr_map.(singleton k v) acc in
      Logs.debug (fun m -> m "follow_cname: entry found, returning");
      `Out (Rcode.NoError, acc', Name_rr_map.empty, t)
    | Ok (`Entries rr_map, t) ->
      let acc' = Domain_name.Map.add name rr_map acc in
      Logs.debug (fun m -> m "follow_cname: entries found, returning");
      `Out (Rcode.NoError, acc', Name_rr_map.empty, t)
    | Ok (`No_domain res, t) ->
      Logs.debug (fun m -> m "follow_cname: nodom");
      `Out (Rcode.NXDomain, acc, to_map res, t)
    | Ok (`No_data res, t) ->
      Logs.debug (fun m -> m "follow_cname: nodata");
      `Out (Rcode.NoError, acc, to_map res, t)
    | Ok (`Serv_fail res, t) ->
      Logs.debug (fun m -> m "follow_cname: servfail") ;
      `Out (Rcode.ServFail, acc, to_map res, t)
  in
  let initial = Domain_name.Map.singleton name Rr_map.(singleton Cname (ttl, alias)) in
  follow t initial alias

(*
let additionals t ts rrs =
  (* TODO: also AAAA *)
  N.fold (fun nam (acc, t) ->
      match cached t ts Udns_enum.A nam with
      | Ok (NoErr answers, t) -> answers @ acc, t
      | _ -> acc, t)
    (Udns_packet.rr_names rrs)
    ([], t)
*)

let answer t ts (name, typ) =
  let packet t _add rcode answer authority =
    (* TODO why was this RA + RD in here? should not be RD for recursive algorithm
       TODO should it be authoritative for recursive algorithm? *)
    let data = (answer, authority) in
    let flags = Packet.Header.FS.singleton `Recursion_desired
    (* XXX: we should look for a fixpoint here ;) *)
    (*    and additional, t = if add then additionals t ts answer else [], t *)
    and data = match rcode with
      | Rcode.NoError -> `Answer data
      | x ->
        let data = if Packet.Query.is_empty data then None else Some data in
        `Rcode_error (x, Opcode.Query, data)
    in
    (flags, data, t)
  in
  match cached t ts typ name with
  | Error e ->
    Logs.warn (fun m -> m "error %a while looking up %a, query"
                  pp_err e Packet.Question.pp (name, typ));
    `Query (name, t)
  | Ok (`No_domain res, t) ->
    Logs.debug (fun m -> m "no domain while looking up %a, query" Packet.Question.pp (name, typ));
    `Packet (packet t false Rcode.NXDomain Domain_name.Map.empty (to_map res))
  | Ok (`No_data res, t) ->
    Logs.debug (fun m -> m "no data while looking up %a" Packet.Question.pp (name, typ));
    `Packet (packet t false Rcode.NoError Domain_name.Map.empty (to_map res))
  | Ok (`Serv_fail res, t) ->
    Logs.debug (fun m -> m "serv fail while looking up %a" Packet.Question.pp (name, typ));
    `Packet (packet t false Rcode.ServFail Domain_name.Map.empty (to_map res))
  | Ok (`Entry (Rr_map.B (k, v)), t) ->
    Logs.debug (fun m -> m "entry while looking up %a" Packet.Question.pp (name, typ));
    let data = Domain_name.Map.singleton name (Rr_map.singleton k v) in
    `Packet (packet t true Rcode.NoError data Domain_name.Map.empty)
  | Ok (`Entries rr_map, t) ->
    Logs.debug (fun m -> m "entries while looking up %a" Packet.Question.pp (name, typ));
    let data = Domain_name.Map.singleton name rr_map in
    `Packet (packet t true Rcode.NoError data Domain_name.Map.empty)
  | Ok (`Alias (ttl, alias), t) ->
    Logs.debug (fun m -> m "alias while looking up %a" Packet.Question.pp (name, typ));
    match typ with
    | Rr.CNAME ->
      let data = Domain_name.Map.singleton name Rr_map.(singleton Cname (ttl, alias)) in
      `Packet (packet t false Rcode.NoError data Domain_name.Map.empty)
    | _ ->
      match follow_cname t ts typ ~name ttl ~alias with
      | `Out (rcode, answer, authority, t) ->
        `Packet (packet t true rcode answer authority)
      | `Query (n, t) -> `Query (n, t)

let handle_query t ~rng ts q =
  match answer t ts q with
  | `Packet (flags, data, t) -> `Reply (flags, data), t
  | `Query (name, t) ->
    let r =
      match snd q with
      (* similar for TLSA, which uses _443._tcp.<name> (not a service name!) *)
      | Rr.SRV when Domain_name.is_service name ->
        Ok (Domain_name.drop_labels_exn ~amount:2 name, Rr.NS)
      | Rr.SRV ->
        Logs.err (fun m -> m "requested SRV record %a, but not a service name"
                     Domain_name.pp name) ;
        Error ()
      | x -> Ok (name, x)
    in
    match r with
    | Error () -> `Nothing, t
    | Ok (qname, typ) ->
      let zone, name', typ, ip, t = resolve t ~rng ts qname typ in
      let name, typ =
        match Domain_name.equal name' qname, snd q with
        | true, Rr.SRV -> name, Rr.SRV
        | _ -> name', typ
      in
      Logs.debug (fun m -> m "resolve returned zone %a name %a typ %a, ip %a"
                     Domain_name.pp zone Domain_name.pp name
                     Rr.pp typ Ipaddr.V4.pp ip) ;
      `Query (zone, name, typ, ip), t
