open Utils

module Cent = functor (R : (sig val value: float end)) -> struct
  include Z

  let of_face_float v = of_float (v *. R.value)
  let to_face_float v = to_float v /. R.value
  let of_face_string v = of_float (float_of_string v *. R.value)
end

module Satoshi = Cent (struct let value = 1e8 end)
module Dollar  = Cent (struct let value = 1e5 end)

module Order = struct
  type kind = Bid | Ask
  type strategy =
    | Market
    | Good_till_cancelled
    | Immediate_or_cancel
    | Fill_or_kill

  let kind_of_string str =
    let caseless = String.lowercase str in
    match caseless with
      | "bid" | "bids" -> Bid
      | "ask" | "asks" -> Ask
      | _ -> failwith "Order.kind_of_string"
end

module type BOOK = sig
  include Map.S with type key = Z.t

  type value = Z.t * int64

  val add : ?ts:int64 -> Z.t -> Z.t -> value t -> value t
  val update : ?ts:int64 -> Z.t -> Z.t -> value t -> value t

  val sum : ?min_v:Z.t -> ?max_v:Z.t -> value t -> Z.t
  val buy_price : value t -> Z.t -> Z.t
  val sell_price : value t -> Z.t -> Z.t

  val amount_below_or_eq : value t -> Z.t -> Z.t
  val amount_above_or_eq : value t -> Z.t -> Z.t

  val arbiter_unsafe : value t -> value t -> Z.t * Z.t
end

(** A book represent the depth for one currency, and one order kind *)
module Book : BOOK = struct
  include ZMap

  type value = Z.t * int64

  let add ?(ts=Unix.getmicrotime_int64 ()) (price:Z.t) (amount:Z.t) (book:value t) =
    ZMap.add price (amount,ts) book

  let update ?(ts=Unix.getmicrotime_int64 ()) price amount book =
    try
      let old_amount, _ = ZMap.find price book in
      ZMap.add price (Z.(old_amount + amount), ts) book
    with Not_found -> ZMap.add price (amount, ts) book

  let sum ?(min_v=Z.(-pow ~$2 128)) ?(max_v=Z.(pow ~$2 128)) book =
    let open Z in
        ZMap.fold
          (fun pr (am,_) acc ->
            if (geq pr min_v) && (leq pr max_v)
            then acc + pr*am else acc)
          book ~$0

  let buy_price ask_book amount =
    let open Z in
        fst (ZMap.fold (fun pr (am,_) (pr_, am_) ->
          match sign (am_ - am) with
            | 1 -> (pr_ + pr*am, am_ - am)
            | 0 -> (pr_ + pr*am, am_ - am)
            | -1 -> (pr_ + pr*am_, ~$0)
            | _ -> failwith ""
        ) ask_book (~$0, amount))

  let sell_price bid_book amount =
    let open Z in
        let bindings = ZMap.bindings bid_book in
        fst (List.fold_right (fun (pr, (am,_)) (pr_,am_) ->
          match sign (am_ - am) with
            | 1 -> (pr_ + pr*am, am_ - am)
            | 0 -> (pr_ + pr*am, am_ - am)
            | -1 -> (pr_ + pr*am_, ~$0)
            | _ -> failwith ""
        ) bindings (~$0, amount))

  let amount_below_or_eq book price =
    let open Z in
        let l, data, r = ZMap.split price book in
        (ZMap.fold (fun pr (am,_) acc -> acc + am)
           l (fst (Opt.unopt ~default:(~$0,0L) data)))

  let amount_above_or_eq book price =
    let open Z in
        let l, data, r = ZMap.split price book in
        (ZMap.fold (fun pr (am,_) acc -> acc + am)
           r (fst (Opt.unopt ~default:(~$0,0L) data)))

  (** Gives the quantity that can be arbitraged. This function does
      not check that [bid] and [ask] are really bid resp. ask books *)
  let arbiter_unsafe bid ask =
    let max_bid = fst (max_binding bid)
    and min_ask = fst (min_binding ask) in
    let qty =
      min (amount_below_or_eq ask max_bid) (amount_above_or_eq bid min_ask) in
    qty, buy_price ask qty

  let diff book1 book2 =
    let open Z in
        let merge_fun key v1 v2 = match v1, v2 with
          | None, None       -> failwith "Should never happen"
          | Some (v1,ts1) , None    -> Some ((~- v1), ts1)
          | None, Some (v2,ts2)    -> Some (v2, ts2)
          | Some (v1,ts1), Some (v2,ts2) -> Some ((v2 - v1), (max ts1 ts2)) in
        ZMap.merge merge_fun book1 book2

  let patch book patch =
    let open Z in
        let merge_fun key v1 v2 = match v1, v2 with
          | None, None -> failwith "Should never happen"
          | Some (v1,ts1), None -> Some (v1, ts1)
          | None, Some (v2,ts2) -> Some (v2, ts2)
          | Some (v1,ts1), Some (v2,ts2) -> Some ((v1 + v2), (max ts1 ts2)) in
        ZMap.merge merge_fun book patch
end


module BooksFunctor = struct
  module Make (B : BOOK) = struct
    type t = (B.value B.t * B.value B.t) StringMap.t

    let (empty:t) = StringMap.empty

    let modify
        (action_fun : ?ts:int64 -> B.key -> B.key -> B.value B.t -> B.value B.t)
        ?(ts=Unix.getmicrotime_int64 ())
        books curr kind price amount =
      let bid, ask =
        try StringMap.find curr books
        with Not_found -> (B.empty, B.empty)  in
      match kind with
        | Order.Bid ->
          let newbook = action_fun ~ts price amount bid in
          StringMap.add curr (newbook, ask) books
        | Order.Ask ->
          let newbook = action_fun ~ts price amount ask in
          StringMap.add curr (bid, newbook) books

    let add = modify B.add
    let update = modify B.update

    let remove books curr = StringMap.remove curr books

    let arbiter_unsafe curr convs (books1:t) basecurr1 (books2:t) basecurr2 =
      let convert_from_base (books:t) basecurr =
        let conv = convs basecurr curr in
        let b1, a1 = StringMap.find basecurr books in
        B.map (fun (am, ts) -> (conv am), ts) b1,
        B.map (fun (am, ts) -> (conv am), ts) a1 in

      let b1, a1 =
        try StringMap.find curr books1
        with Not_found -> convert_from_base books1 basecurr1
      and b2, a2 =
        try StringMap.find curr books2
        with Not_found -> convert_from_base books2 basecurr2
      in
      let am1, sum1 = (B.arbiter_unsafe b1 a2)
      and am2, sum2 = (B.arbiter_unsafe b2 a1) in
      if Z.(gt am1 ~$0)
      then
        let sell_pr = B.sell_price b2 am1 in
        ((am1, Z.(sell_pr - sum1)), (am2, sum2))
      else
        let sell_pr = B.sell_price b1 am2 in
        ((am1, sum1), Z.(am2, sell_pr - sum2))


    let print books =
      let print_one book = Book.iter
        (fun price (amount,ts) -> Printf.printf "(%f,%f) "
          (Dollar.to_face_float price)
          (Satoshi.to_face_float amount)) book in
      StringMap.iter (fun curr (bid,ask) ->
        Printf.printf "BID %s\n" curr;
        print_one bid; print_endline "";
        Printf.printf "ASK %s\n" curr;
        print_one ask; print_endline ""
      ) books
  end
end

module Books = BooksFunctor.Make(Book)
