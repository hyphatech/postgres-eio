let order_placed conn ~id = Postgres_eio.notify conn ~channel:"orders" id
