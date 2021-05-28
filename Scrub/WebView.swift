//
//  WebView.swift
//  Scrub
//
//  Created by Shinichiro Oba on 2021/04/15.
//

import SwiftUI
import Combine
import ScratchWebKit

enum WebViewError: Error {
    case invalidUrl
}

extension WebViewError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .invalidUrl:
            return NSLocalizedString("Invalid URL", comment: "Invalid URL")
        }
    }
}

struct WebView: UIViewControllerRepresentable {
    
    @ObservedObject var viewModel: WebViewModel
    @Binding var url: URL?
    
    @EnvironmentObject private var alertController: AlertController
    
    private let webViewController = ScratchWebViewController()
    
    func makeCoordinator() -> WebView.Coodinator {
        print(#function)
        return Coodinator(self)
    }
    
    func makeUIViewController(context: Context) -> ScratchWebViewController {
        print(#function)
        webViewController.delegate = context.coordinator
        
        if let url = url, url.scheme != "file" {
            webViewController.load(url: url)
        } else if let url = viewModel.homeUrl {
            webViewController.load(url: url)
        } else {
            alertController.showAlert(error: WebViewError.invalidUrl)
        }
        
        return webViewController
    }
    
    func updateUIViewController(_ uiViewController: ScratchWebViewController, context: Context) {
        print(#function)
    }
}

extension WebView {
    
    class Coodinator: NSObject, ScratchWebViewControllerDelegate {
        
        private let parent : WebView
        
        private var cancellables: Set<AnyCancellable> = []
        
        init(_ parent: WebView) {
            self.parent = parent
            
            parent.viewModel.inputs.sink { (inputs) in
                switch inputs {
                case .goHome:
                    if let url = parent.viewModel.homeUrl {
                        parent.webViewController.load(url: url)
                    } else {
                        parent.alertController.showAlert(error: WebViewError.invalidUrl)
                    }
                case .goBack:
                    parent.webViewController.goBack()
                case .goForward:
                    parent.webViewController.goForward()
                case .load(url: let url):
                    parent.webViewController.load(url: url)
                case .reload:
                    parent.webViewController.reload()
                case .stopLoading:
                    parent.webViewController.stopLoading()
                }
            }.store(in: &cancellables)
            
            parent.webViewController.$url.sink { (url) in
                DispatchQueue.main.async {
                    parent.url = url
                }
            }.store(in: &cancellables)
            
            parent.webViewController.$isLoading.assign(to: &parent.viewModel.$isLoading)
            parent.webViewController.$estimatedProgress.assign(to: &parent.viewModel.$estimatedProgress)
            parent.webViewController.$canGoBack.assign(to: &parent.viewModel.$canGoBack)
            parent.webViewController.$canGoForward.assign(to: &parent.viewModel.$canGoForward)
        }
        
        func didDownloadFile(at url: URL) {
            let vc = UIDocumentPickerViewController(forExporting: [url])
            vc.shouldShowFileExtensions = true
            parent.webViewController.present(vc, animated: true)
        }
        
        func didFail(error: Error) {
            parent.alertController.showAlert(error: error)
        }
    }
}
