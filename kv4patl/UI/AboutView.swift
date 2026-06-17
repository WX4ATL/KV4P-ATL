// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI

struct AboutView: View {
    @State private var sourcesExpanded = false
    @State private var licensesExpanded = false

    private let citations = [
        "Vagell, Vance. \"VanceVagell/kv4p-ht.\" GitHub, 2026, https://github.com/VanceVagell/kv4p-ht.",
        "Vagell, Vance. \"KV4P HT App Icon Artwork.\" kv4p-ht, GitHub, 2026, https://github.com/VanceVagell/kv4p-ht/tree/main/artwork.",
        "Free Software Foundation. GNU General Public License, Version 3. Free Software Foundation, 29 June 2007, https://www.gnu.org/licenses/gpl-3.0.en.html.",
        "Free Software Foundation. \"Frequently Asked Questions about the GNU Licenses.\" GNU Project, 2026, https://www.gnu.org/licenses/gpl-faq.html.",
        "Vagell, Vance. \"Releases: kv4p HT v2.0.0.0-v2.0.0.1.\" GitHub, 2026, https://github.com/VanceVagell/kv4p-ht/releases.",
        "raff. \"raff/kv4p-go.\" GitHub, 2025, https://github.com/raff/kv4p-go.",
        "lupettohf. \"kv4p-sharp.\" GitHub, 2026, https://github.com/lupettohf/kv4p-sharp.",
        "Alta Software. \"alta/swift-opus.\" GitHub, 2021, https://github.com/alta/swift-opus.",
        "GitHub Docs. \"Licensing a Repository.\" GitHub, 2026, https://docs.github.com/en/repositories/managing-your-repositorys-settings-and-features/customizing-your-repository/licensing-a-repository.",
        "Apple Inc. \"Working with Accessories.\" Apple Developer, 2026, https://developer.apple.com/accessories/.",
        "Apple Inc. \"Frequently Asked Questions.\" MFi Program, 2026, https://mfi.apple.com/en/faqs.",
        "Apple Inc. \"Charge and Connect with the USB-C Connector on Your iPhone.\" Apple Support, 2026, https://support.apple.com/en-ie/105099.",
        "Apple Inc. \"Licensed Application End User License Agreement.\" Apple Legal, 2026, https://www.apple.com/legal/internet-services/itunes/dev/stdeula/.",
        "Apple Inc. \"Provide a Custom License Agreement.\" App Store Connect Help, 2026, https://developer.apple.com/help/app-store-connect/manage-app-information/provide-a-custom-license-agreement/.",
        "Apple Inc. \"App Review Guidelines.\" Apple Developer, 2026, https://developer.apple.com/app-store/review/guidelines/.",
        "Apple Inc. \"Handling Audio Interruptions.\" Apple Developer Documentation, 2026, https://developer.apple.com/documentation/avfaudio/handling-audio-interruptions.",
        "Apple Inc. \"AVAudioApplication.\" Apple Developer Documentation, 2026, https://developer.apple.com/documentation/avfaudio/avaudioapplication.",
        "Apple Inc. \"routeChangeNotification.\" Apple Developer Documentation, 2026, https://developer.apple.com/documentation/avfaudio/avaudiosession/routechangenotification.",
        "Apple Inc. \"allowBluetoothHFP.\" Apple Developer Documentation, 2026, https://developer.apple.com/documentation/avfaudio/avaudiosession/categoryoptions-swift.struct/allowbluetoothhfp.",
        "Apple Inc. \"allowBluetoothA2DP.\" Apple Developer Documentation, 2026, https://developer.apple.com/documentation/avfaudio/avaudiosession/categoryoptions-swift.struct/allowbluetootha2dp.",
        "Apple Inc. \"defaultToSpeaker.\" Apple Developer Documentation, 2026, https://developer.apple.com/documentation/avfaudio/avaudiosession/categoryoptions-swift.struct/defaulttospeaker.",
        "Apple Inc. \"preferredIOBufferDuration.\" Apple Developer Documentation, 2026, https://developer.apple.com/documentation/avfaudio/avaudiosession/preferrediobufferduration.",
        "Apple Inc. \"setActive(_:options:).\" Apple Developer Documentation, 2026, https://developer.apple.com/documentation/AVFAudio/AVAudioSession/setActive%28_%3Aoptions%3A%29.",
        "Apple Inc. \"setPreferredInput(_:).\" Apple Developer Documentation, 2026, https://developer.apple.com/documentation/avfaudio/avaudiosession/setpreferredinput%28_%3A%29.",
        "Apple Inc. \"availableInputs.\" Apple Developer Documentation, 2026, https://developer.apple.com/documentation/AVFAudio/AVAudioSession/availableInputs.",
        "Apple Inc. \"Technical Q&A QA1799: AVAudioSession - Microphone Selection.\" Apple Developer Documentation Archive, 8 May 2014, https://developer.apple.com/library/archive/qa/qa1799/_index.html.",
        "Apple Inc. \"Core Bluetooth.\" Apple Developer Documentation, 2026, https://developer.apple.com/documentation/corebluetooth.",
        "Apple Inc. \"Best Practices for Interacting with a Remote Peripheral Device.\" Core Bluetooth Programming Guide, 18 Sept. 2013, https://developer.apple.com/library/archive/documentation/NetworkingInternetWeb/Conceptual/CoreBluetooth_concepts/BestPracticesForInteractingWithARemotePeripheralDevice/BestPracticesForInteractingWithARemotePeripheralDevice.html.",
        "Apple Inc. \"Technical Q&A QA1931: Using the Correct Bluetooth LE Advertising and Connection Parameters for a Stable Connection.\" Apple Developer Documentation Archive, 13 July 2017, https://developer.apple.com/library/archive/qa/qa1931/_index.html.",
        "Apple Inc. \"Transferring Data Between Bluetooth Low Energy Devices.\" Apple Developer Documentation, 2026, https://developer.apple.com/documentation/CoreBluetooth/transferring-data-between-bluetooth-low-energy-devices.",
        "Apple Inc. \"centralManager(_:didDisconnectPeripheral:error:).\" Apple Developer Documentation, 2026, https://developer.apple.com/documentation/corebluetooth/cbcentralmanagerdelegate/centralmanager(_:diddisconnectperipheral:error:).",
        "Apple Inc. \"connect(_:options:).\" Apple Developer Documentation, 2026, https://developer.apple.com/documentation/corebluetooth/cbcentralmanager/connect(_:options:).",
        "Apple Inc. \"CBL2CAPChannel.\" Apple Developer Documentation, 2026, https://developer.apple.com/documentation/corebluetooth/cbl2capchannel.",
        "Apple Inc. \"openL2CAPChannel(_:).\" Apple Developer Documentation, 2026, https://developer.apple.com/documentation/corebluetooth/cbperipheral/openl2capchannel(_:).",
        "Apple Inc. \"Requesting Authorization to Use Location Services.\" Apple Developer Documentation, 2026, https://developer.apple.com/documentation/corelocation/requesting-authorization-to-use-location-services.",
        "Apple Inc. \"requestLocation().\" Apple Developer Documentation, 2026, https://developer.apple.com/documentation/corelocation/cllocationmanager/requestlocation().",
        "Apple Inc. \"Human Interface Guidelines.\" Apple Developer Documentation, 2026, https://developer.apple.com/design/human-interface-guidelines.",
        "Apple Inc. \"App Icons.\" Human Interface Guidelines, 2026, https://developer.apple.com/design/human-interface-guidelines/app-icons.",
        "Apple Inc. \"Icon Composer.\" Apple Developer, 2026, https://developer.apple.com/icon-composer/.",
        "Apple Inc. \"Creating Your App Icon Using Icon Composer.\" Apple Developer Documentation, 2026, https://developer.apple.com/documentation/Xcode/creating-your-app-icon-using-icon-composer.",
        "Apple Inc. \"Say Hello to the New Look of App Icons.\" WWDC25, 2025, https://developer.apple.com/videos/play/wwdc2025/220/.",
        "Apple Inc. \"Create Icons with Icon Composer.\" WWDC25, 2025, https://developer.apple.com/videos/play/wwdc2025/361/.",
        "Apple Inc. \"Designing for iOS.\" Human Interface Guidelines, 2026, https://developer.apple.com/design/human-interface-guidelines/designing-for-ios.",
        "Apple Inc. \"Layout.\" Human Interface Guidelines, 2026, https://developer.apple.com/design/human-interface-guidelines/layout.",
        "Apple Inc. \"Form.\" SwiftUI Documentation, 2026, https://developer.apple.com/documentation/swiftui/form.",
        "Apple Inc. \"List.\" SwiftUI Documentation, 2026, https://developer.apple.com/documentation/SwiftUI/List.",
        "Apple Inc. \"TextField.\" SwiftUI Documentation, 2026, https://developer.apple.com/documentation/SwiftUI/TextField.",
        "Apple Inc. \"ViewThatFits.\" SwiftUI Documentation, 2026, https://developer.apple.com/documentation/swiftui/viewthatfits.",
        "Apple Inc. \"What's New in Core Bluetooth.\" WWDC 2017 Session 712 PDF, 2017, https://devstreaming-cdn.apple.com/videos/wwdc/2017/712jqzhsxoww3zn/712/712_whats_new_in_core_bluetooth.pdf.",
        "Chrome Developers. \"The Serial API.\" Chrome for Developers, 2026, https://developer.chrome.com/docs/capabilities/serial.",
        "ESPHome. \"ESP Web Tools.\" GitHub, 2026, https://github.com/esphome/esp-web-tools.",
        "ESPHome. \"ESP Web Tools License.\" GitHub, 2026, https://github.com/esphome/esp-web-tools/blob/main/LICENSE.",
        "Lit Contributors. \"lit.\" GitHub, 2026, https://github.com/lit/lit.",
        "Material Web Contributors. \"material-web.\" GitHub, 2026, https://github.com/material-components/material-web.",
        "Espressif Systems. \"GAP API.\" ESP-IDF Programming Guide, 2026, https://docs.espressif.com/projects/esp-idf/en/stable/esp32/api-reference/bluetooth/esp_gap_ble.html.",
        "Espressif Systems. \"GATT Server API.\" ESP-IDF Programming Guide, 2026, https://docs.espressif.com/projects/esp-idf/en/stable/esp32/api-reference/bluetooth/esp_gatts.html.",
        "Espressif Systems. \"Bluetooth LE and Bluetooth.\" ESP-FAQ, 2026, https://docs.espressif.com/projects/esp-faq/en/latest/software-framework/bt/ble.html.",
        "Espressif Systems. \"BLE.\" Arduino-ESP32 Documentation, 2026, https://docs.espressif.com/projects/arduino-esp32/en/latest/api/ble.html.",
        "Espressif Systems. \"Basic Commands.\" Esptool Documentation, 2026, https://docs.espressif.com/projects/esptool/en/latest/esp32/esptool/basic-commands.html.",
        "ESPHome. \"ESP Web Tools.\" ESP Web Tools, 2026, https://esphome.github.io/esp-web-tools/.",
        "NiceRF Wireless Technology Co., Ltd. SA818 Walkie Talkie Module Programming Manual. NiceRF, 2015.",
        "Interactive Multimedia Association. Recommended Practices for Enhancing Digital Audio Compatibility in Multimedia Systems. IMA, 21 Oct. 1992, https://www.cs.columbia.edu/~hgs/audio/dvi/IMA_ADPCM.pdf.",
        "MultimediaWiki Contributors. \"IMA ADPCM.\" MultimediaWiki, 2026, https://wiki.multimedia.cx/index.php/IMA_ADPCM.",
        "Tucson Amateur Packet Radio Corporation. AX.25 Link Access Protocol for Amateur Packet Radio. Version 2.2, 1997.",
        "APRS Working Group. APRS Protocol Reference. Version 1.0.1, 29 Aug. 2000, https://www.aprs.org/doc/APRS101.PDF.",
        "APRS Working Group. APRS Protocol Reference. Version 1.0.1, 29 Aug. 2000, https://www.ui-view.net/files/APRS101.pdf.",
        "TAPR Software Library. \"APRS Protocol Specification.\" Tucson Amateur Packet Radio, 2026, https://web.tapr.org/software_library/aprs/aprsspec/spec/aprs101/.",
        "Bruninga, Bob, and APRS Contributors. \"APRS 1.2 Draft Specification Repository.\" GitHub, 2026, https://github.com/wb2osz/aprsspec.",
        "Langner, John, WB2OSZ. \"Dire Wolf.\" GitHub, 2026, https://github.com/wb2osz/direwolf.",
        "Langner, John, WB2OSZ. A Better APRS Packet Demodulator, Part 1: 1200 Baud. Dire Wolf Documentation, 2015.",
        "Sailer, Thomas, and Marat Fayzullin. \"multimon-ng.\" GitHub, 2026, https://github.com/EliasOenal/multimon-ng.",
        "Toledo, Sivan, 4X6IZ. \"A High-Performance Sound-Card AX.25 Modem.\" TAPR/ARRL Digital Communications Conference, 2012.",
        "\"AFSK.\" Not Black Magic, 2026, https://www.notblackmagic.com/bitsnpieces/afsk/.",
        "Lassila, Heikki. \"Specification for KISS over BLE (Bluetooth Low Energy).\" aprs-specs, GitHub, 2026, https://github.com/hessu/aprs-specs/blob/master/BLE-KISS-API.md.",
        "Lassila, Heikki. \"New Symbol Graphics and Better Support for Alternate Symbol Tables.\" aprs.fi Blog, 3 Nov. 2015, https://blog.aprs.fi/2015/11/new-symbol-graphics-and-better-support.html."
    ]

    private let licenseNotices = [
        "KV4P/ATL, the BLE firmware overlay, the web flasher glue, and KV4P-derived artwork are distributed under the GNU General Public License, version 3 or, at your option, any later version. You may run, study, copy, modify, and redistribute the GPL-covered parts under GPL-3.0-or-later.",
        "For GPL-covered components, no app EULA, store term, support term, or distribution note in this project is intended to reduce the rights granted by GPL-3.0-or-later. If another term conflicts with the GPL for GPL-covered components, the GPL controls for those components.",
        "Public binary releases include complete corresponding source for the exact app and firmware build distributed to users. Corresponding source includes Swift source, Objective-C bridge files, firmware overlay source, web flasher source, build scripts, project files, assets, license notices, and rebuild instructions.",
        "KV4P HT upstream Android app, firmware, protocol behavior, and artwork are copyright Vance Vagell and KV4P HT contributors. KV4P/ATL app code, BLE firmware overlay, web flasher glue, build scripts, and adaptations in this workspace are copyright 2026 Blake Ross WX4ATL.",
        "The KV4P/ATL app icon is an Apple Icon Composer document derived from GPL-covered KV4P radio glyph artwork. The icon source layers are included as GPL-covered corresponding source.",
        "The app bundle retains upstream KV4P third-party notices verbatim, including MIT, SIL Open Font License 1.1, LGPLv3, GPLv3, Apache-2.0, and BSD-3-Clause materials that upstream KV4P retained in other-licenses.txt.",
        "The web flasher redistributes ESP Web Tools 10.0.1 under Apache-2.0 and bundled Google web-component code under Apache-2.0 and BSD-3-Clause notices. Those readable license texts are included in the app Settings legal area and in the web flasher package.",
        "raff/kv4p-go, kv4p-sharp, alta/swift-opus, APRS/AX.25 specifications, Dire Wolf, multimon-ng, 4X6IZ AX.25 modem materials, Not Black Magic AFSK notes, and IMA ADPCM references were used as protocol, interoperability, DSP, or historical research references. They are not linked into KV4P/ATL app code.",
        "KV4P/ATL currently displays APRS map markers using SF Symbols and local code-derived APRS symbol metadata. No third-party APRS symbol artwork pack is bundled in the current app binary.",
        "Public App Store releases use the bundled GPL-preserving End User License Agreement. The agreement names Blake Ross WX4ATL as licensor, identifies the public source location as https://github.com/WX4ATL/KV4P-ATL, states that GPL-3.0-or-later controls for GPL-covered components, and does not impose further restrictions on GPL rights.",
        "KV4P/ATL and the companion firmware are provided as-is without warranty of any kind, including without limitation the implied warranties of merchantability, fitness for a particular purpose, and non-infringement, to the extent permitted by law.",
        "Users are responsible for complying with applicable amateur-radio laws, frequency privileges, station identification, power limits, local rules, and safe RF operation requirements."
    ]

    var body: some View {
        KV4PScreen {
            KV4PCard {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Developed by Blake Ross WX4ATL")
                        .font(.title.bold())
                }
            }

            KV4PCard("KV4P/ATL", systemImage: "radio") {
                Text("Native SwiftUI radio control for KV4P HT using the KV4P 2.0 KISS protocol over a BLE bridge.")
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 8) {
                    Label("USB-C powers the radio path.", systemImage: "cable.connector")
                    Label("BLE carries app data.", systemImage: "antenna.radiowaves.left.and.right")
                    Label("APRS uses AX.25 UI frames over KISS DATA.", systemImage: "message")
                    Label("Voice uses 8 kHz mono IMA ADPCM frames.", systemImage: "waveform")
                }
            }

            KV4PCard("Licenses", systemImage: "checkmark.shield") {
                DisclosureGroup(isExpanded: $licensesExpanded) {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(licenseNotices, id: \.self) { notice in
                            Text(notice)
                                .font(.footnote)
                                .textSelection(.enabled)
                        }
                        Text("The iOS Settings app also includes the complete license texts, End User License Agreement, retained upstream other-licenses.txt, and third-party notices under KV4P/ATL > Licenses, Credits & Attributions.")
                            .font(.footnote.weight(.semibold))
                            .textSelection(.enabled)
                    }
                    .padding(.top, 8)
                } label: {
                    Text("\(licenseNotices.count) compliance notes")
                        .foregroundStyle(.secondary)
                }
            }

            KV4PCard("Sources", systemImage: "books.vertical") {
                DisclosureGroup(isExpanded: $sourcesExpanded) {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(citations, id: \.self) { citation in
                            Text(citation)
                                .font(.footnote)
                                .textSelection(.enabled)
                        }
                    }
                    .padding(.top, 8)
                } label: {
                    Text("\(citations.count) MLA citations")
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}
