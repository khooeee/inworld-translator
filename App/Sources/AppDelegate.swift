import UIKit

@main
final class AppDelegate: UIResponder, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        configurationForConnecting connectingSceneSession: UISceneSession,
        options: UIScene.ConnectionOptions
    ) -> UISceneConfiguration {
        UISceneConfiguration(name: "Default Configuration", sessionRole: connectingSceneSession.role)
    }
}

final class SceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?
    private var environment: AppEnvironment?

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
        guard let windowScene = scene as? UIWindowScene else { return }
        let environment = AppEnvironment()
        self.environment = environment

        let navigation = UINavigationController()
        let translation = TranslationViewController(viewModel: environment.viewModel) { [weak navigation] in
            let keyScreen = APIKeyViewController(store: environment.keyStore, baseURL: environment.baseURL) {
                environment.viewModel.apiKeyChanged()
            }
            navigation?.present(UINavigationController(rootViewController: keyScreen), animated: true)
        }
        navigation.viewControllers = [translation]
        navigation.navigationBar.prefersLargeTitles = false

        let window = UIWindow(windowScene: windowScene)
        window.rootViewController = navigation
        window.makeKeyAndVisible()
        self.window = window

        if environment.autoStart {
            environment.viewModel.start()
        }
    }

    func sceneDidEnterBackground(_ scene: UIScene) {
        // Captions can't be read in the background, and Inworld bills for
        // every second of audio sent, so leaving the screen stops listening.
        guard let viewModel = environment?.viewModel, viewModel.isRunning else { return }
        viewModel.stop(notice: .stoppedInBackground)
    }
}
