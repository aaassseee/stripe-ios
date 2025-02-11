//
//  VerificationSheetController.swift
//  StripeIdentity
//
//  Created by Mel Ludowise on 10/7/21.
//

import UIKit
@_spi(STP) import StripeCore
@_spi(STP) import StripeUICore

protocol VerificationSheetControllerDelegate: AnyObject {
    /**
     Invoked when the user has closed the flow.
     - Parameters:
       - controller: The `VerificationSheetController` that determined the flow result.
       - result: The result of the user's verification flow.
                 Value is `.flowCompleted` if the user successfully completed the flow.
                 Value is `.flowCanceled` if the user closed the view controller prior to completing the flow.
     */
    func verificationSheetController(
        _ controller: VerificationSheetControllerProtocol,
        didFinish result: IdentityVerificationSheet.VerificationFlowResult
    )
}

protocol VerificationSheetControllerProtocol: AnyObject {
    var verificationSessionId: String { get }
    var ephemeralKeySecret: String { get }
    var apiClient: IdentityAPIClient { get }
    var flowController: VerificationSheetFlowControllerProtocol { get }
    var mlModelLoader: IdentityMLModelLoaderProtocol { get }
    var dataStore: VerificationPageDataStore { get }

    var delegate: VerificationSheetControllerDelegate? { get set }

    func loadAndUpdateUI()

    func saveData(
        completion: @escaping (VerificationSheetAPIContent) -> Void
    )

    func saveDocumentFileData(
        documentUploader: DocumentUploaderProtocol,
        completion: @escaping (VerificationSheetAPIContent) -> Void
    )

    func submit(
        completion: @escaping (VerificationSheetAPIContent) -> Void
    )
}

@available(iOS 13, *)
final class VerificationSheetController: VerificationSheetControllerProtocol {

    weak var delegate: VerificationSheetControllerDelegate?

    let verificationSessionId: String
    let ephemeralKeySecret: String

    let apiClient: IdentityAPIClient
    let flowController: VerificationSheetFlowControllerProtocol
    let mlModelLoader: IdentityMLModelLoaderProtocol
    let dataStore = VerificationPageDataStore()

    /// Content returned from the API
    var apiContent = VerificationSheetAPIContent()

    init(
        verificationSessionId: String,
        ephemeralKeySecret: String,
        apiClient: IdentityAPIClient = STPAPIClient.makeIdentityClient(),
        flowController: VerificationSheetFlowControllerProtocol = VerificationSheetFlowController(),
        mlModelLoader: IdentityMLModelLoaderProtocol = IdentityMLModelLoader()
    ) {
        self.verificationSessionId = verificationSessionId
        self.ephemeralKeySecret = ephemeralKeySecret
        self.apiClient = apiClient
        self.flowController = flowController
        self.mlModelLoader = mlModelLoader

        flowController.delegate = self
    }

    /// Makes API calls to load the verification sheet. When the API response is complete, transitions to the first screen in the flow.
    func loadAndUpdateUI() {
        load {
            self.flowController.transitionToNextScreen(
                apiContent: self.apiContent,
                sheetController: self,
                completion: { }
            )
        }
    }

    /**
     Makes API calls to load the verification sheet.
     - Note: `completion` block is always executed on the main thread.
     */
    func load(
        completion: @escaping () -> Void
    ) {
        // Start API request
        apiClient.getIdentityVerificationPage(
            id: verificationSessionId,
            ephemeralKeySecret: ephemeralKeySecret
        ).observe(on: .main) { [weak self] result in
            // API request finished
            guard let self = self else { return }
            self.apiContent.setStaticContent(result: result)
            self.startLoadingMLModels()
            completion()
        }
    }

    func startLoadingMLModels() {
        guard let staticContent = apiContent.staticContent else {
            return
        }

        mlModelLoader.startLoadingDocumentModels(
            from: staticContent.documentCapture.models
        )
    }

    /**
     Saves the values in `dataStore` to server
     - Note: `completion` block is always executed on the main thread.
     */
    func saveData(
        completion: @escaping (VerificationSheetAPIContent) -> Void
    ) {
        apiClient.updateIdentityVerificationPageData(
            id: verificationSessionId,
            updating: dataStore.toAPIModel,
            ephemeralKeySecret: ephemeralKeySecret
        ).observe(on: .main) { [weak self] result in
            guard let self = self else {
                // Always call completion block even if `self` has been deinitialized
                completion(VerificationSheetAPIContent())
                return
            }
            self.apiContent.setSessionData(result: result)

            completion(self.apiContent)
        }
    }

    /**
     Waits until documents are done uploading then saves to data store and API endpoint
     - Note: `completion` block is always executed on the main thread.
     */
    func saveDocumentFileData(
        documentUploader: DocumentUploaderProtocol,
        completion: @escaping (VerificationSheetAPIContent) -> Void
    ) {
        documentUploader.frontBackUploadFuture.observe(on: .main) { [weak self] result in
            guard let self = self else { return }

            switch result {
            case .success((let frontFileData, let backFileData)):
                self.dataStore.frontDocumentFileData = frontFileData
                self.dataStore.backDocumentFileData = backFileData
                self.saveData(completion: completion)
            case .failure(let error):
                self.apiContent.lastError = error
                completion(self.apiContent)
            }
        }
    }

    /**
     Submits the VerificationSession
     - Note: `completion` block is always executed on the main thread.
     */
    func submit(
        completion: @escaping (VerificationSheetAPIContent) -> Void
    ) {
        apiClient.submitIdentityVerificationPage(
            id: verificationSessionId,
            ephemeralKeySecret: ephemeralKeySecret
        ).observe(on: .main) { [weak self] result in
            guard let self = self else {
                // Always call completion block even if `self` has been deinitialized
                completion(VerificationSheetAPIContent())
                return
            }
            self.apiContent.setSessionData(result: result)

            completion(self.apiContent)
        }
    }
}

// MARK: - VerificationSheetFlowControllerDelegate

@available(iOS 13, *)
extension VerificationSheetController: VerificationSheetFlowControllerDelegate {
    func verificationSheetFlowControllerDidDismiss(_ flowController: VerificationSheetFlowControllerProtocol) {
        let result: IdentityVerificationSheet.VerificationFlowResult =
            (apiContent.submitted == true) ? .flowCompleted : .flowCanceled
        delegate?.verificationSheetController(self, didFinish: result)
    }
}
