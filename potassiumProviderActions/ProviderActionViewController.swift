import FileProvider
import FileProviderUI
import PotassiumProviderCore
import SwiftUI

#if os(macOS)
import AppKit
#else
import UIKit
#endif

@objc(ProviderActionViewController)
public final class ProviderActionViewController: FPUIActionExtensionViewController {
    private var actionModel: ProviderActionViewModel?

    #if os(macOS)
    public override func loadView() {
        view = NSView()
    }
    #else
    public override func loadView() {
        view = UIView()
    }
    #endif

    public override func prepare(
        forAction actionIdentifier: String,
        itemIdentifiers: [NSFileProviderItemIdentifier]
    ) {
        guard let domainIdentifier = extensionContext.domainIdentifier?.rawValue,
              itemIdentifiers.count == 1,
              let itemIdentifier = itemIdentifiers.first,
              let mode = ProviderActionViewModel.Mode(actionIdentifier: actionIdentifier) else {
            cancel(with: "The selected kDrive action is unavailable.")
            return
        }

        let model = ProviderActionViewModel(
            mode: mode,
            domainIdentifier: domainIdentifier,
            itemIdentifier: itemIdentifier
        )
        actionModel = model
        install(
            ProviderActionRootView(
                model: model,
                complete: { [weak self] in self?.extensionContext.completeRequest() }
            )
        )
        Task { await model.load() }
    }

    private func cancel(with message: String) {
        extensionContext.cancelRequest(
            withError: NSError(
                domain: FPUIErrorDomain,
                code: Int(FPUIExtensionErrorCode.failed.rawValue),
                userInfo: [NSLocalizedDescriptionKey: message]
            )
        )
    }

    private func install<Content: View>(_ content: Content) {
        #if os(macOS)
        let hostingController = NSHostingController(rootView: content)
        addChild(hostingController)
        hostingController.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(hostingController.view)
        NSLayoutConstraint.activate([
            hostingController.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            hostingController.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            hostingController.view.topAnchor.constraint(equalTo: view.topAnchor),
            hostingController.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            view.widthAnchor.constraint(greaterThanOrEqualToConstant: 460),
            view.heightAnchor.constraint(greaterThanOrEqualToConstant: 520),
        ])
        #else
        let hostingController = UIHostingController(rootView: content)
        addChild(hostingController)
        hostingController.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(hostingController.view)
        NSLayoutConstraint.activate([
            hostingController.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            hostingController.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            hostingController.view.topAnchor.constraint(equalTo: view.topAnchor),
            hostingController.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        hostingController.didMove(toParent: self)
        #endif
    }
}
