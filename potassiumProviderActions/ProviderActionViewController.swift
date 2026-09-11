import FileProvider
import FileProviderUI
import PotassiumProviderCore
import SwiftUI

#if os(macOS)
import AppKit
#if STABILITY
import Combine
#endif
#else
import UIKit
#endif

@objc(ProviderActionViewController)
public final class ProviderActionViewController: FPUIActionExtensionViewController {
    private var actionModel: ProviderActionViewModel?
    private var loadTask: Task<Void, Never>?
    #if os(macOS) && STABILITY
    private var panelIdentityObservation: AnyCancellable?
    #endif

    deinit { loadTask?.cancel() }

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
        loadTask?.cancel()
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
                complete: { [weak self] in
                    self?.loadTask?.cancel()
                    self?.extensionContext.completeRequest()
                }
            )
        )
        #if os(macOS) && STABILITY
        // FileProviderUI's hosted NavigationStack does not expose its SwiftUI
        // identifier through AX. Publish the verified identity on the native root.
        view.setAccessibilityElement(true)
        view.setAccessibilityRole(.group)
        view.setAccessibilityIdentifier(nil)
        panelIdentityObservation = model.$stabilityPanelAlias.sink { [weak self] alias in
            guard let alias else { return }
            self?.view.setAccessibilityIdentifier("provider.stability.action." + alias.uuidString)
        }
        #endif
        loadTask = Task { await model.load() }
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
        for child in children {
            child.view.removeFromSuperview()
            child.removeFromParent()
        }
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
