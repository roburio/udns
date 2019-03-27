(* (c) 2017, 2018 Hannes Mehnert, all rights reserved *)

open Udns_resolver_entry

open Rresult.R.Infix

module N = Domain_name.Set
module NM = Domain_name.Map

let invalid_soa name =
  let p pre =
    match Domain_name.(prepend name "invalid" >>= fun n -> prepend n pre) with
    | Ok name -> name
    | Error _ -> name
  in
  let soa = {
    Udns.Soa.nameserver = p "ns" ; hostmaster = p "hostmaster" ;
    serial = 1l ; refresh = 16384l ; retry = 2048l ;
    expiry = 1048576l ; minimum = 300l
  } in
  name, (300l, soa)

let soa_map name soa =
  Domain_name.Map.singleton name Udns.Map.(singleton Soa soa)

let invalid_soa_map name = soa_map name (snd (invalid_soa name))


(*
let noerror bailiwick { Udns.Question.q_type ; q_name } hdr dns =
  (* maybe should be passed explicitly (when we don't do qname minimisation) *)
  let in_bailiwick name = Domain_name.sub ~domain:bailiwick ~subdomain:name in
  (* ANSWER *)
  let typ_matches rr =
    let rtyp = Udns_packet.rdata_to_rr_typ rr.Udns_packet.rdata in
    match q_type, rtyp with
    | Udns_enum.ANY, _ -> true
    | _, Udns_enum.CNAME -> true
    | t, t' -> t = t'
  in
  let answers, anames =
    match List.filter (fun rr -> Domain_name.equal rr.Udns_packet.name q.q_name && typ_matches rr) dns.Udns_packet.answer with
    | [] ->
      (* NODATA (no answer, but SOA (or not) in authority) *)
      begin
        (* RFC2308, Sec 2.2 "No data":
           - answer is empty
           - authority has a) SOA + NS, b) SOA, or c) nothing *)
        (* an example for this behaviour is NS:
           asking for AAAA www.soup.io, get empty answer + SOA in authority
           asking for AAAA coffee.soup.io, get empty answer + authority *)
        (* XXX don't think the Dns_name.sub check is worth it - could be equal *)
        let rank = if hdr.Udns_packet.authoritative then AuthoritativeAuthority else Additional in
        match
          List.partition
            (fun rr -> Domain_name.sub ~subdomain:q.q_name ~domain:rr.Udns_packet.name &&
                       match rr.rdata with SOA _ -> true | _ -> false)
            dns.authority
        with
        | [ soa ], _ -> [ q.q_type, q.q_name, rank, NoData soa ]
        | [], [] when not hdr.truncation ->
          Logs.warn (fun m -> m "noerror answer, but nothing in authority whose sub is %a (%a) in %a, invalid_soa!"
                        Domain_name.pp q.q_name Udns_enum.pp_rr_typ q.q_type Udns_packet.pp_rrs dns.authority) ;
          [ q.q_type, q.q_name, Additional, NoData (invalid_soa q.q_name) ]
        | _, _ -> [] (* general case when we get an answer from root server *)
      end, N.empty
    | answer ->
      let rank = if hdr.authoritative then AuthoritativeAnswer else NonAuthoritativeAnswer in
      match List.partition (fun rr -> match rr.Udns_packet.rdata with Udns_packet.CNAME _ -> true | _ -> false) answer with
      | [], entries ->
        (* TODO should we filter based on q.q_type? *)
        (* TODO rr_names is problematic:
           query a foo.com answer mx 10 foo.com bar.com additional bar.com a 1.2.3.4 *)
        (* XXX: if non-empty, we should require authority to be set? does it help? *)
        [ q.q_type, q.q_name, rank, NoErr entries ], Udns_packet.rr_names entries
      | [ cname ], [] ->
        (* explicitly register as CNAME so it'll be found *)
        [ Udns_enum.CNAME, q.q_name, rank, NoErr [ cname ] ], N.empty
      | _, _ ->
        (* case multiple cnames or cname and sth else *)
        (* fail hard already here!? -- there's either multiple cname or cname and others *)
        Logs.warn (fun m -> m "noerror answer with right name, but not either one or no cname in %a, invalid soa for %a (%a)"
                      Udns_packet.pp_rrs answer Domain_name.pp q.q_name Udns_enum.pp_rr_typ q.q_type) ;
        [ q.q_type, q.q_name, rank, NoData (invalid_soa q.q_name) ], N.empty
  in

  (* AUTHORITY - NS records *)
  let ns, nsnames =
    (* authority points us to NS of q_name! *)
    (* we collect a list of NS records and the ns names *)
    (* TODO need to be more careful, q: foo.com a: foo.com a 1.2.3.4 au: foo.com ns blablubb.com ad: blablubb.com A 1.2.3.4 *)
    let nm, names =
      List.fold_left (fun (acc, s) rr ->
          if in_bailiwick rr.Udns_packet.name then
            let ns = match NM.find rr.Udns_packet.name acc with
              | None -> []
              | Some ns -> ns
            in
            match rr.Udns_packet.rdata with
            | Udns_packet.NS name -> NM.add rr.Udns_packet.name (rr :: ns) acc, Domain_name.Set.add name s
            | _ -> (acc, s)
          else (acc, s)) (NM.empty, Domain_name.Set.empty) dns.authority
    in
    let rank = if hdr.authoritative then AuthoritativeAuthority else Additional in
    NM.fold (fun name rrs acc ->
        (Udns_enum.NS, name, rank, NoErr rrs) :: acc)
      nm [], names
  in

  (* ADDITIONAL *)
  (* maybe only these thingies which are subdomains of q_name? *)
  (* preserve A/AAAA records only for NS lookups? *)
  (* now we have processed:
     - answer (filtered to where name = q_name)
     - authority with SOA and NS entries
     - names from these answers, and authority
     - additional section can contain glue records if needed
     - only A and AAAA records are of interest for glue *)
  let glues =
    let names = N.union anames nsnames in
    let names = N.filter in_bailiwick names in
    let aaaaa =
      List.fold_left (fun acc rr ->
          if N.mem rr.Udns_packet.name names then
            let a, aaaa = match NM.find rr.name acc with
              | None -> [], []
              | Some x -> x
            in
            match rr.rdata with
            | A _ -> NM.add rr.name (rr :: a, aaaa) acc
            | AAAA _ -> NM.add rr.name (a, rr :: aaaa) acc
            | _ -> acc
          else acc)
        NM.empty dns.additional
    in
    List.flatten
      (List.map (fun (nam, (a, aaaa)) ->
           let f t = function
             | [] -> []
             | rr -> [ t, nam, Additional, NoErr rr ]
           in
           f Udns_enum.A a @ f Udns_enum.AAAA aaaa)
          (NM.bindings aaaaa))
  in
  (* This is defined in RFC2181, Sec9 -- answer is unique if authority or
     additional is non-empty *)
  let answer_complete = dns.authority <> [] || dns.additional <> [] in
  match answers, ns with
  | [], [] when not answer_complete && hdr.truncation ->
    (* special handling for truncated replies.. better not add anything *)
    Logs.warn (fun m -> m "truncated reply for %a (%a), ignoring completely"
                  Domain_name.pp q.q_name Udns_enum.pp_rr_typ q.q_type) ;
    []
  | [], [] ->
    (* not sure if this can happen, maybe discard everything? *)
    Logs.warn (fun m -> m "reply without answers or ns invalid so for %a (%a)"
                  Domain_name.pp q.q_name Udns_enum.pp_rr_typ q.q_type) ;
    [ q.q_type, q.q_name, Additional, NoData (invalid_soa q.q_name) ]
  | _, _ -> answers @ ns @ glues
*)

let find_soa name dns =
  let rec go name =
    match Domain_name.Map.find name dns.Udns.authority with
    | None -> go (Domain_name.drop_labels_exn name)
    | Some rrmap -> match Udns.Map.(find Soa rrmap) with
      | None -> go (Domain_name.drop_labels_exn name)
      | Some (ttl, soa) -> name, (ttl, soa)
  in
  try Some (go name) with Invalid_argument _ -> None

let nxdomain { Udns.Question.q_type ; q_name } hdr dns =
  (* we can't do much if authoritiative is not set (some auth dns do so) *)
  (* There are cases where answer is non-empty, but contains a CNAME *)
  (* RFC 2308 Sec 1 + 2.1 show that NXDomain is for the last QNAME! *)
  (* -> need to potentially extract CNAME(s) *)
  let cname_opt =
    let rec go acc name =
      match Domain_name.Map.find name dns.Udns.answer with
      | None -> acc
      | Some rrmap -> match Udns.Map.(find Cname rrmap) with
        | None -> acc
        | Some (ttl, alias) -> go ((name, (ttl, alias)) :: acc) alias
    in
    go [] q_name
  in
  let soa = find_soa q_name dns in
  (* since NXDomain have CNAME semantics, we store them as CNAME *)
  let rank = if Udns.Header.FS.mem `Authoritative hdr.Udns.Header.flags then AuthoritativeAnswer else NonAuthoritativeAnswer in
  (* we conclude NXDomain, there are 3 cases we care about:
     no soa in authority and no cname answer -> inject an invalid_soa (avoid loops)
     a matching soa, no cname -> NoDom q_name
     _, a matching cname -> NoErr q_name with cname
 *)
  match soa, cname_opt with
  | None, [] ->
    let name, soa = invalid_soa q_name in
    [ Udns_enum.CNAME, q_name, rank, NoDom (name, soa) ]
  | Some (name, soa), [] -> [ Udns_enum.CNAME, q_name, rank, NoDom (name, soa) ]
  | _, rrs ->
    List.map (fun (name, cname) ->
        Udns_enum.CNAME, name, rank, NoErr Udns.Map.(B (Cname, cname)))
      rrs

let noerror_stub { Udns.Question.q_name ; q_type } dns =
  (* no glue, just answers - but get all the cnames *)
  let find_entry_or_cname name =
    match Domain_name.Map.find name dns.Udns.answer with
    | None -> None
    | Some rrmap -> match q_type with
      | Udns_enum.ANY -> Some (`Entries rrmap)
      | _ -> match Udns.Map.lookup_rr q_type rrmap with
        | Some b -> Some (`Entry b)
        | None -> match Udns.Map.(find Cname rrmap) with
          | None -> None
          | Some (ttl, alias) -> Some (`Cname (ttl, alias))
  in
  let rec go acc name = match find_entry_or_cname name with
    | None ->
      let name, soa = match find_soa name dns with Some x -> x | None -> invalid_soa name in
      (q_type, name, NonAuthoritativeAnswer, NoData (name, soa)) :: acc
    | Some (`Cname (ttl, alias)) ->
      let b = Udns.Map.(B (Cname, (ttl, alias))) in
      go ((Udns_enum.CNAME, name, NonAuthoritativeAnswer, NoErr b) :: acc) alias
    | Some (`Entry b) ->
      (q_type, name, NonAuthoritativeAnswer, NoErr b) :: acc
    | Some (`Entries map) ->
      Udns.Map.fold (fun Udns.Map.(B (k, v) as b) acc ->
          (Udns.Map.k_to_rr_typ k, name, NonAuthoritativeAnswer, NoErr b) :: acc)
        map acc
  in
  go [] q_name

(* stub vs recursive: maybe sufficient to look into *)
let scrub ?(mode = `Recursive) zone q hdr dns =
  Logs.debug (fun m -> m "scrubbing (bailiwick %a) q %a rcode %a"
                 Domain_name.pp zone Udns.Question.pp q
                 Udns_enum.pp_rcode hdr.Udns.Header.rcode) ;
  match mode, hdr.rcode with
  (*  | `Recursive, Udns_enum.NoError -> Ok (noerror zone q hdr dns) *)
  | `Stub, Udns_enum.NoError -> Ok (noerror_stub q dns)
  | _, Udns_enum.NXDomain -> Ok (nxdomain q hdr dns)
  | `Stub, Udns_enum.ServFail ->
    let ttl, soa = invalid_soa q.q_name in
    Ok [ Udns_enum.CNAME, q.q_name, NonAuthoritativeAnswer, ServFail (ttl, soa)  ]
  | _, e -> Error e
