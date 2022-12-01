# Issuing Apple Developer Certificate on Linux

Generate CSR:

```bash
openssl req -nodes -newkey rsa:2048 -keyout dev.key -out dev.csr
```

Send it to Apple, get `developerID_application.cer` in DER format.

Convert from DER to PEM:

```bash
openssl x509 -inform der -in developerID_application.cer -out dev.crt
```

Pack certificate and key into PKCS12:

```bash
openssl pkcs12 -export -in dev.crt -inkey dev.key -out dev.p12
```

Import `dev.p12` into macOS keychain.
