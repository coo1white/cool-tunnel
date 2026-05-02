# Disclaimer

COOL TUNNEL is a free, open-source macOS client that wraps the upstream
[NaiveProxy](https://github.com/klzgrad/naiveproxy) protocol. It is provided
**as-is**, for educational and research purposes only.

## Intended use

This software is intended for legitimate uses such as:

- Learning how SOCKS / HTTPS proxies and PAC files interact with macOS network
  settings.
- Operating a personal proxy on infrastructure you own or are explicitly
  authorised to use.
- Performing security research, auditing, and academic study.

This software is **not** intended to facilitate any activity that would
violate applicable law in the jurisdiction where it is used.

## User responsibility

By downloading, building, installing, or running COOL TUNNEL you acknowledge
and agree that:

1. **Compliance with local law is solely your responsibility.** The authors
   neither endorse nor encourage any illegal activity, including but not
   limited to unauthorised circumvention of network restrictions imposed by
   law, your employer, your school, or any service whose terms of use you
   have accepted.
2. **You will not use this software to violate the terms of service of any
   network you do not own or operate.**
3. **You will configure the upstream server (the `naive` endpoint) yourself.**
   COOL TUNNEL ships no preconfigured server, no embedded credentials, and no
   directory of public servers. The application cannot connect anywhere until
   you provide your own server address and credentials.
4. **You assume all risk** arising from running this software on your own
   hardware or any hardware you have permission to use.

## No warranty

This software is distributed under the **GNU Affero General Public License,
Version 3** (see [LICENSE](./LICENSE)). It is provided **without any
warranty** — express or implied — including without limitation the warranties
of merchantability, fitness for a particular purpose, and non-infringement.

## No liability

In no event shall the authors, contributors, or copyright holders be liable
for any claim, damages, or other liability — whether in an action of contract,
tort, or otherwise — arising from, out of, or in connection with the
software or the use or other dealings in the software.

## No data collection

COOL TUNNEL does not collect, transmit, or analyse any user data. There is
no telemetry, no analytics, and no remote configuration. Proxy credentials
are stored on the user's device — passwords in the macOS Keychain, the rest
in the standard `UserDefaults` store. The application does not contact any
remote service except the SOCKS upstream you configure yourself.

## Bundled components

COOL TUNNEL bundles a precompiled `naive` Mach-O binary built from
[klzgrad/naiveproxy](https://github.com/klzgrad/naiveproxy), which is
distributed under the BSD-3-Clause license. Users redistributing COOL TUNNEL
must comply with that license in addition to AGPL-3.0.

## Reporting security issues

If you discover a security vulnerability in COOL TUNNEL, please report it
privately via a [GitHub Security Advisory](https://github.com/coo1white/cool-tunnel/security/advisories/new)
rather than as a public issue.
