(lang dune 3.18)
(name postgres-eio)

(generate_opam_files true)

(maintainers "Hypha Technologies Ltd <dev@hyphatech.io>")

(authors "Hypha Technologies Ltd")

(license MIT)

(maintenance_intent "(latest)")

(source
 (github hyphatech/postgres-eio))

(package
 (name postgres-eio)
 (synopsis "A native Postgres driver for OCaml 5 and Eio")
 (description
  "Protocol 3.0 and 3.2 over TCP, a Unix socket or TLS; SCRAM with channel binding, MD5 and client certificates; statements cached and pipelined, COPY both ways, LISTEN/NOTIFY, binary results and a pool, every failure a value.")
 (depends
  (ocaml
   (>= 5.4))
  (eio
   (>= 1.5))
  (tls
   (>= 2.1.2))
  (tls-eio
   (>= 2.1.2))
  (x509
   (>= 1.1.1))
  (ca-certs
   (>= 1.0.3))
  (ptime
   (>= 1.2.0))
  (uuidm
   (>= 0.9.10))
  (mirage-crypto-rng
   (>= 2.4.1))
  (domain-name
   (>= 0.5.0))
  (ipaddr
   (>= 5.6.2))
  (digestif
   (>= 1.3.1))
  (base64
   (>= 3.5.2))
  (cstruct
   (>= 6.3.0))
  (mtime
   (>= 2.1.0))
  (logs
   (>= 0.10.0))
  (uunf
   (>= 18.0.0))
  (eio_main
   (and
    :with-test
    (>= 1.5)))
  (alcotest
   (and
    :with-test
    (>= 1.9.1)))
  (qcheck-core
   (and
    :with-test
    (>= 0.91)))
  (qcheck-alcotest
   (and
    :with-test
    (>= 0.91)))
  (ocamlformat
   (and
    :with-dev-setup
    (= 0.29.0)))
  (odoc
   (and
    :with-dev-setup
    (>= 3.2.1)))))
