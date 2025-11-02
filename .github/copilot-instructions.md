# GitHub Copilot Instructions for True Balance Client

## Project Guidelines

### Documentation
- **Never add new .md documentation files** to the project
- Keep documentation minimal and focused
- Use inline code comments for complex logic instead of separate documentation files

### Code Organization
- **Keep code compartmentalized** to avoid large files
- Target: Keep files under 500-800 lines when possible
- Break large files into smaller, focused modules
- Use separate files for:
  - Different features/screens
  - Reusable widgets
  - Services and utilities
  - Data models
  - Constants and configurations

### File Structure Best Practices
- Create separate files for custom widgets that are used in multiple places
- Extract business logic into service classes
- Keep UI code separate from data fetching/manipulation logic
- Use the `lib/` directory structure effectively:
  - `lib/screens/` - Screen/page widgets
  - `lib/widgets/` - Reusable widget components
  - `lib/services/` - Business logic and API calls
  - `lib/models/` - Data models
  - `lib/utils/` - Utility functions
  - `lib/constants/` - App-wide constants

### When Refactoring Large Files
- Identify logical sections that can be extracted
- Create new files with descriptive names
- Update imports in the original file
- Ensure all functionality remains intact

### Current Issues to Address
- `lib/main.dart` is currently very large (~6000 lines)
- Consider breaking it into:
  - Separate screen widgets
  - Reusable component files
  - Service/helper classes for Firebase operations
  - Separate files for dialogs and complex widgets

## Flutter-Specific Guidelines
- Follow Flutter best practices for widget composition
- Keep StatefulWidget and StatelessWidget files focused on single responsibilities
- Extract complex builder methods into separate widget classes
- Use const constructors wherever possible for better performance
