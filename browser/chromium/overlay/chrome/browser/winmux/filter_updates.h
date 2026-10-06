#ifndef CHROME_BROWSER_WINMUX_FILTER_UPDATES_H_
#define CHROME_BROWSER_WINMUX_FILTER_UPDATES_H_
class Profile;
namespace winmux {
void StartFilterUpdates(Profile* profile, bool permitted);
}
#endif
