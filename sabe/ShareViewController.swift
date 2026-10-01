//
//  ShareViewController.swift
//  sabe (Share Extension)
//
//  Created for Sabe app.
//

import UIKit
import Social
import UniformTypeIdentifiers

final class ShareViewController: UIViewController {

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
        processSharedContent()
    }

    private func processSharedContent() {
        guard let extensionItem = extensionContext?.inputItems.first as? NSExtensionItem,
              let attachments = extensionItem.attachments else {
            completeExtension()
            return
        }

        // Buscar URLs o Texto compartidos desde TikTok / Instagram / Safari
        let urlType = UTType.url.identifier
        let plainTextType = UTType.plainText.identifier

        for provider in attachments {
            if provider.hasItemConformingToTypeIdentifier(urlType) {
                provider.loadItem(forTypeIdentifier: urlType, options: nil) { [weak self] (item, error) in
                    if let url = item as? URL {
                        self?.openMainApp(with: url.absoluteString)
                    } else if let urlString = item as? String {
                        self?.openMainApp(with: urlString)
                    } else {
                        self?.completeExtension()
                    }
                }
                return
            } else if provider.hasItemConformingToTypeIdentifier(plainTextType) {
                provider.loadItem(forTypeIdentifier: plainTextType, options: nil) { [weak self] (item, error) in
                    if let text = item as? String {
                        self?.openMainApp(with: text)
                    } else {
                        self?.completeExtension()
                    }
                }
                return
            }
        }

        completeExtension()
    }

    private func openMainApp(with sharedText: String) {
        guard let encoded = sharedText.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let deepLinkURL = URL(string: "sabe://share?url=\(encoded)") else {
            completeExtension()
            return
        }

        // Abrir app principal mediante el esquema deep link
        var responder: UIResponder? = self
        while responder != nil {
            if let application = responder as? UIApplication {
                application.open(deepLinkURL, options: [:]) { [weak self] _ in
                    self?.completeExtension()
                }
                return
            }
            responder = responder?.next
        }

        // Fallback usando openURL selector en extensionContext
        let selector = sel_registerName("openURL:")
        var contextResponder: UIResponder? = self
        while contextResponder != nil {
            if contextResponder?.responds(to: selector) == true {
                contextResponder?.perform(selector, with: deepLinkURL)
                break
            }
            contextResponder = contextResponder?.next
        }

        completeExtension()
    }

    private func completeExtension() {
        extensionContext?.completeRequest(returningItems: [], completionHandler: nil)
    }
}
