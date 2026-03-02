import SwiftUI

class AppThemeManager: ObservableObject {
    @Published var isDarkMode: Bool = true
    
    // Semantic Colors based on active theme
    var bgColor: Color { isDarkMode ? AppTheme.darkBg : AppTheme.lightBg }
    var surface1: Color { isDarkMode ? AppTheme.darkSurface1 : AppTheme.lightSurface1 }
    var surface2: Color { isDarkMode ? AppTheme.darkSurface2 : AppTheme.lightSurface2 }
    var textPrimary: Color { isDarkMode ? AppTheme.darkTextPrimary : AppTheme.lightTextPrimary }
    var textSecondary: Color { isDarkMode ? AppTheme.darkTextSecondary : AppTheme.lightTextSecondary }
    
    var colorScheme: ColorScheme {
        return isDarkMode ? .dark : .light
    }
    
    func toggleTheme() {
        withAnimation {
            isDarkMode.toggle()
        }
    }
}
