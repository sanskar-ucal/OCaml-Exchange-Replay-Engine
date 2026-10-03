open Types
let unwrap = function Ok x -> x | Error e -> invalid_arg e
let generate ~seed count =
  if count < 0 then invalid_arg "negative workload size";
  let rng = Random.State.make [| seed |] in
  let id i = unwrap (Id.of_string ("o" ^ string_of_int i)) in
  let existing i = id (Random.State.int rng (max 1 i)) in
  Array.init count (fun i ->
    let choice = Random.State.int rng 100 in
    if choice < 15 then Cancel (existing i)
    else if choice < 25 then
      Reduce (existing i, unwrap (Quantity.of_int (1 + Random.State.int rng 20)))
    else
      let side = if Random.State.bool rng then Buy else Sell in
      let quantity = unwrap (Quantity.of_int (1 + Random.State.int rng 40)) in
      let kind_choice = Random.State.int rng 100 in
      let kind = if kind_choice < 10 then Market else
        let price = unwrap (Price.of_int (10_000 + Random.State.int rng 21)) in
        let tif = if kind_choice < 75 then Gtc else if kind_choice < 85 then Ioc
          else if kind_choice < 93 then Fok else Post_only in
        Limit (price, tif) in
      Submit { id = id i; side; quantity; kind })
