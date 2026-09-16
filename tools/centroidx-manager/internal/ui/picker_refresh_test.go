package ui

import (
	"errors"
	"strings"
	"testing"
	"time"

	"github.com/centroid-is/centroidx-manager/internal/update"
)

// A refresh must pick up what was published since the picker opened. Before
// this, the list was fetched once at launch and never again, so a station left
// on the picker went on reporting "Up to date" past a new main-latest.
func TestLandReleases_RefreshReplacesTheList(t *testing.T) {
	state := &pickerState{selected: -1, notesCacheFor: -1, channel: update.ChannelLatest}
	gen := state.beginLoad(false)
	state.landReleases(gen, mainLatestAt(time.Date(2026, 9, 1, 8, 0, 0, 0, time.UTC)), nil, time.Now())

	newer := time.Date(2026, 9, 16, 9, 30, 0, 0, time.UTC)
	gen = state.beginLoad(true)
	if !state.landReleases(gen, mainLatestAt(newer), nil, time.Now()) {
		t.Fatal("a current refresh must be applied")
	}
	if got := state.releases[0].PublishedAt; !got.Equal(newer) {
		t.Errorf("expected the refreshed build published %v, got %v", newer, got)
	}
	if state.loading || state.refreshing {
		t.Error("expected loading and refreshing to be cleared once the refresh lands")
	}
	if len(state.itemClicks) != len(state.releases) {
		t.Errorf("expected one clickable per release, got %d for %d", len(state.itemClicks), len(state.releases))
	}
}

// A refresh keeps the list on screen while it runs — the operator reading a
// release's notes must not see it blank out every few minutes.
func TestBeginLoad_RefreshKeepsTheListVisible(t *testing.T) {
	state := &pickerState{selected: -1, notesCacheFor: -1, channel: update.ChannelStable}
	state.landReleases(state.beginLoad(false), buildTestReleases(), nil, time.Now())
	state.selected = 1

	state.beginLoad(true)
	if state.loading {
		t.Error("a refresh must not put the picker back into its loading screen")
	}
	if !state.refreshing {
		t.Error("expected refreshing=true while the refresh runs")
	}
	if len(state.releases) != 3 || state.selected != 1 {
		t.Errorf("expected the list and selection untouched, got %d releases, selected=%d", len(state.releases), state.selected)
	}
}

// A channel switch is a new list, not a refresh of the old one.
func TestBeginLoad_ChannelSwitchClearsTheList(t *testing.T) {
	state := &pickerState{selected: -1, notesCacheFor: -1, channel: update.ChannelStable}
	state.landReleases(state.beginLoad(false), buildTestReleases(), nil, time.Now())
	state.selected = 1

	state.beginLoad(false)
	if !state.loading || state.releases != nil || state.selected != -1 {
		t.Errorf("expected a cleared, loading picker; got loading=%v releases=%d selected=%d",
			state.loading, len(state.releases), state.selected)
	}
}

// The selection follows the version, not the row: a new release landing on top
// shifts every row down by one, and the notes and Install button must still
// be for the release the operator picked.
func TestLandReleases_SelectionFollowsTheVersion(t *testing.T) {
	state := &pickerState{selected: -1, notesCacheFor: -1, channel: update.ChannelStable}
	state.landReleases(state.beginLoad(false), buildTestReleases(), nil, time.Now())
	state.selected = 1 // 2026.3.6
	_ = state.notesLines()

	withNewer := append([]update.ReleaseInfo{{
		Version:     "2026.10.2",
		Notes:       "- Newest",
		PublishedAt: time.Date(2026, 10, 2, 0, 0, 0, 0, time.UTC),
	}}, buildTestReleases()...)
	state.landReleases(state.beginLoad(true), withNewer, nil, time.Now())

	if got := state.selectedVersion(); got != "2026.3.6" {
		t.Errorf("expected the selection to stay on 2026.3.6, got %q (row %d)", got, state.selected)
	}
	if lines := state.notesLines(); len(lines) == 0 || lines[0] != "## Release 2026.3.6" {
		t.Errorf("expected the notes of 2026.3.6, got %q", lines)
	}
}

func TestLandReleases_SelectionClearsWhenTheVersionIsGone(t *testing.T) {
	state := &pickerState{selected: -1, notesCacheFor: -1, channel: update.ChannelStable}
	state.landReleases(state.beginLoad(false), buildTestReleases(), nil, time.Now())
	state.selected = 2 // 2026.3.5

	state.landReleases(state.beginLoad(true), buildTestReleases()[:2], nil, time.Now())
	if state.selected != -1 {
		t.Errorf("expected no selection once the selected release is withdrawn, got row %d", state.selected)
	}
}

// Two loads in flight (a refresh, then a channel switch or a second refresh):
// only the newest may land, whichever response arrives last.
func TestLandReleases_SupersededLoadIsDropped(t *testing.T) {
	state := &pickerState{selected: -1, notesCacheFor: -1, channel: update.ChannelStable}
	old := state.beginLoad(false)
	current := state.beginLoad(true)

	state.landReleases(current, buildTestReleases()[:1], nil, time.Now())
	if state.landReleases(old, buildTestReleases(), nil, time.Now()) {
		t.Error("a superseded load must report that it was dropped")
	}
	if len(state.releases) != 1 {
		t.Errorf("expected the current load's single release, got %d", len(state.releases))
	}
}

// A refresh that fails keeps the list it already had — a network blip must
// not take away the versions the operator was looking at — and says so.
func TestLandReleases_FailedRefreshKeepsTheList(t *testing.T) {
	state := &pickerState{selected: -1, notesCacheFor: -1, channel: update.ChannelStable}
	checked := time.Date(2026, 9, 16, 9, 0, 0, 0, time.UTC)
	state.landReleases(state.beginLoad(false), buildTestReleases(), nil, checked)
	state.selected = 0

	state.landReleases(state.beginLoad(true), nil, errors.New("dial tcp: no such host"), checked.Add(5*time.Minute))
	if len(state.releases) != 3 || state.selected != 0 {
		t.Errorf("expected the list and selection kept, got %d releases, selected=%d", len(state.releases), state.selected)
	}
	if state.refreshErr == nil {
		t.Error("expected the failed refresh to be reported")
	}
	if state.err != nil {
		t.Error("a failed refresh must not masquerade as an install error")
	}
	if !state.lastChecked.Equal(checked) {
		t.Errorf("a failed refresh must not move the last-checked time, got %v", state.lastChecked)
	}
	if next := state.nextAutoRefresh(); !next.Equal(checked.Add(5 * time.Minute).Add(autoRefreshInterval)) {
		t.Errorf("a failed refresh must still wait a full interval before retrying, got %v", next)
	}

	state.landReleases(state.beginLoad(true), buildTestReleases(), nil, checked.Add(10*time.Minute))
	if state.refreshErr != nil {
		t.Error("a successful refresh must clear the previous refresh error")
	}
}

// With no list yet, a failure is the picker's error screen, as before.
func TestLandReleases_FailedFirstLoadIsAnError(t *testing.T) {
	state := &pickerState{selected: -1, notesCacheFor: -1, channel: update.ChannelStable}
	state.landReleases(state.beginLoad(false), nil, errors.New("connection refused"), time.Now())
	if state.err == nil || state.loading {
		t.Errorf("expected the error screen, got err=%v loading=%v", state.err, state.loading)
	}
}

func TestAutoRefreshDue(t *testing.T) {
	landed := time.Date(2026, 9, 16, 9, 0, 0, 0, time.UTC)
	state := &pickerState{selected: -1, notesCacheFor: -1, channel: update.ChannelLatest}
	state.landReleases(state.beginLoad(false), mainLatestAt(landed), nil, landed)

	if state.autoRefreshDue(landed.Add(autoRefreshInterval - time.Second)) {
		t.Error("not due before the interval has passed")
	}
	if !state.autoRefreshDue(landed.Add(autoRefreshInterval)) {
		t.Error("due once the interval has passed")
	}

	// Never mid-install or mid-wizard: the wizard installs state.selected, and
	// a list changing under it could install a different release.
	state.installing = true
	if state.autoRefreshDue(landed.Add(time.Hour)) {
		t.Error("must not refresh while installing")
	}
	state.installing = false
	state.wizard.step = stepDestination
	if state.autoRefreshDue(landed.Add(time.Hour)) {
		t.Error("must not refresh while the install wizard is open")
	}
	state.wizard.step = stepNone

	state.beginLoad(true)
	if state.autoRefreshDue(landed.Add(time.Hour)) {
		t.Error("must not start a second refresh while one is running")
	}
}

// The bar must say how old the list is, and a list that could not be
// re-checked must not read as a current one.
func TestCheckedCaption(t *testing.T) {
	state := &pickerState{selected: -1, notesCacheFor: -1, channel: update.ChannelStable}
	if text, _ := checkedCaption(state); text != "" {
		t.Errorf("nothing checked yet: expected no caption, got %q", text)
	}

	checked := time.Date(2026, 9, 16, 9, 30, 0, 0, time.UTC)
	state.landReleases(state.beginLoad(false), buildTestReleases(), nil, checked)
	stamp := checked.Local().Format("15:04")
	if text, failed := checkedCaption(state); text != "Checked "+stamp || failed {
		t.Errorf("expected %q, got %q (failed=%v)", "Checked "+stamp, text, failed)
	}

	state.beginLoad(true)
	if text, _ := checkedCaption(state); text != "Checking..." {
		t.Errorf("expected the caption to show the check in progress, got %q", text)
	}

	state.landReleases(state.loadGen, nil, errors.New("connection refused"), checked.Add(5*time.Minute))
	if text, failed := checkedCaption(state); !failed || !strings.Contains(text, stamp) {
		t.Errorf("expected a failure caption naming the list's age %s, got %q (failed=%v)", stamp, text, failed)
	}
}
