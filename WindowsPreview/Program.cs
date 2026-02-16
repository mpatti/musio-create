using System.Diagnostics;

Console.Title = "Musio Create - Windows Preview";

WriteBanner();
WriteStatus();
WriteActions();

while (true)
{
    Console.Write("\nSelect an option (1-4): ");
    var input = Console.ReadLine()?.Trim();

    switch (input)
    {
        case "1":
            OpenUrl("https://github.com/mpatti/musio-create");
            break;
        case "2":
            OpenUrl("https://github.com/mpatti/musio-create/actions");
            break;
        case "3":
            OpenUrl("https://github.com/mpatti/musio-create/blob/windows-morning-build/docs/windows-build-and-run.md");
            break;
        case "4":
            Console.WriteLine("\nThanks for trying Musio Create Windows Preview.");
            return;
        default:
            Console.WriteLine("Invalid input. Enter 1, 2, 3, or 4.");
            break;
    }
}

static void WriteBanner()
{
    Console.ForegroundColor = ConsoleColor.Cyan;
    Console.WriteLine(@"===============================================");
    Console.WriteLine(@"       MUSIO CREATE - WINDOWS PREVIEW");
    Console.WriteLine(@"===============================================");
    Console.ResetColor();
}

static void WriteStatus()
{
    Console.WriteLine("\nThis preview is a launchable Windows milestone artifact.");
    Console.WriteLine("It validates CI packaging + download/run flow on Windows.");

    Console.WriteLine("\nWhat works now:");
    Console.WriteLine("  - Runs as a native Windows executable");
    Console.WriteLine("  - Provides links to source, CI artifacts, and run docs");

    Console.WriteLine("\nNot yet in this preview executable:");
    Console.WriteLine("  - DAW timeline + transport UI");
    Console.WriteLine("  - Audio backend (WASAPI/ASIO) integration");
    Console.WriteLine("  - VST3 loading / plugin editor hosting");

    Console.WriteLine("\nThis is intentionally transparent: no unsupported capability is faked.");
}

static void WriteActions()
{
    Console.WriteLine("\nActions:");
    Console.WriteLine("  [1] Open Musio Create repository");
    Console.WriteLine("  [2] Open GitHub Actions runs");
    Console.WriteLine("  [3] Open Windows build-and-run docs");
    Console.WriteLine("  [4] Exit");
}

static void OpenUrl(string url)
{
    try
    {
        Process.Start(new ProcessStartInfo
        {
            FileName = url,
            UseShellExecute = true
        });
        Console.WriteLine($"Opened: {url}");
    }
    catch (Exception ex)
    {
        Console.WriteLine($"Could not open browser automatically: {ex.Message}");
        Console.WriteLine($"Open this URL manually: {url}");
    }
}
