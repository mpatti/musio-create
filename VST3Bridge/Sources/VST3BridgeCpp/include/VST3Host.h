/*
 * VST3Host.h
 * C interface for hosting VST3 plugins from Swift
 * 
 * NOTE: To use this bridge, you must:
 * 1. Download the VST3 SDK from Steinberg
 * 2. Link against the VST3 SDK libraries
 * 3. The VST3 SDK is licensed under a proprietary license for commercial use
 */

#ifndef VST3Host_h
#define VST3Host_h

#include <stdint.h>
#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

// MARK: - Opaque Types

/// Opaque handle to a VST3 plugin module
typedef struct VST3Module* VST3ModuleRef;

/// Opaque handle to a VST3 plugin instance
typedef struct VST3Instance* VST3InstanceRef;

// MARK: - Plugin Information

/// Basic plugin information
typedef struct {
    char name[256];
    char vendor[256];
    char version[64];
    char category[64];
    char subcategory[64];
    char classID[64];        // Class ID (GUID) as string
    bool hasEditor;          // Has custom UI
    bool isSynth;           // Is an instrument
    int32_t numAudioInputs;
    int32_t numAudioOutputs;
    int32_t numEventInputs;   // MIDI/event inputs
    int32_t numEventOutputs;
} VST3PluginInfo;

/// Parameter information
typedef struct {
    uint32_t id;
    char name[256];
    char shortName[64];
    char units[32];
    double defaultValue;
    double minValue;
    double maxValue;
    int32_t stepCount;       // 0 = continuous, >0 = discrete
    bool canAutomate;
    bool isReadOnly;
    bool isList;             // Is a discrete list parameter
} VST3ParameterInfo;

// MARK: - Audio Processing

/// Audio buffer configuration
typedef struct {
    int32_t sampleRate;
    int32_t maxBlockSize;
    int32_t numChannels;
    bool is64Bit;            // 64-bit processing
} VST3ProcessSetup;

/// Audio buffers for processing
typedef struct {
    float** inputs;          // [channel][sample]
    float** outputs;
    int32_t numInputChannels;
    int32_t numOutputChannels;
    int32_t numSamples;
} VST3AudioBuffers;

/// MIDI event for processing
typedef struct {
    int32_t sampleOffset;    // Sample offset in buffer
    uint8_t status;          // MIDI status byte
    uint8_t data1;
    uint8_t data2;
    uint8_t channel;
} VST3MIDIEvent;

// MARK: - Module Management

/// Scan a directory for VST3 plugins
/// Returns number of plugins found, fills info array up to maxCount
int32_t VST3ScanDirectory(
    const char* path,
    VST3PluginInfo* infos,
    int32_t maxCount
);

/// Scan default VST3 plugin locations
int32_t VST3ScanDefaultLocations(
    VST3PluginInfo* infos,
    int32_t maxCount
);

/// Load a VST3 module from path
VST3ModuleRef VST3ModuleLoad(const char* path);

/// Unload a VST3 module
void VST3ModuleUnload(VST3ModuleRef module);

/// Get number of plugins in module
int32_t VST3ModuleGetPluginCount(VST3ModuleRef module);

/// Get plugin info at index
bool VST3ModuleGetPluginInfo(
    VST3ModuleRef module,
    int32_t index,
    VST3PluginInfo* info
);

// MARK: - Instance Management

/// Create a plugin instance from module
VST3InstanceRef VST3InstanceCreate(
    VST3ModuleRef module,
    int32_t pluginIndex
);

/// Create a plugin instance by class ID
VST3InstanceRef VST3InstanceCreateByID(
    VST3ModuleRef module,
    const char* classID
);

/// Destroy a plugin instance
void VST3InstanceDestroy(VST3InstanceRef instance);

/// Initialize for audio processing
bool VST3InstanceSetup(
    VST3InstanceRef instance,
    const VST3ProcessSetup* setup
);

/// Activate the plugin
bool VST3InstanceActivate(VST3InstanceRef instance);

/// Deactivate the plugin
bool VST3InstanceDeactivate(VST3InstanceRef instance);

// MARK: - Audio Processing

/// Process audio and MIDI
bool VST3InstanceProcess(
    VST3InstanceRef instance,
    VST3AudioBuffers* buffers,
    const VST3MIDIEvent* midiEvents,
    int32_t numMIDIEvents
);

/// Set processing active/inactive
void VST3InstanceSetActive(VST3InstanceRef instance, bool active);

// MARK: - Parameters

/// Get number of parameters
int32_t VST3InstanceGetParameterCount(VST3InstanceRef instance);

/// Get parameter info
bool VST3InstanceGetParameterInfo(
    VST3InstanceRef instance,
    int32_t index,
    VST3ParameterInfo* info
);

/// Get parameter value (normalized 0-1)
double VST3InstanceGetParameter(
    VST3InstanceRef instance,
    uint32_t parameterId
);

/// Set parameter value (normalized 0-1)
bool VST3InstanceSetParameter(
    VST3InstanceRef instance,
    uint32_t parameterId,
    double value
);

/// Begin parameter edit (for automation/gestures)
void VST3InstanceBeginEdit(VST3InstanceRef instance, uint32_t parameterId);

/// End parameter edit
void VST3InstanceEndEdit(VST3InstanceRef instance, uint32_t parameterId);

// MARK: - State/Presets

/// Get preset data size
int32_t VST3InstanceGetStateSize(VST3InstanceRef instance);

/// Save state to buffer (returns actual size written)
int32_t VST3InstanceSaveState(
    VST3InstanceRef instance,
    uint8_t* buffer,
    int32_t bufferSize
);

/// Load state from buffer
bool VST3InstanceLoadState(
    VST3InstanceRef instance,
    const uint8_t* buffer,
    int32_t size
);

/// Get number of factory presets
int32_t VST3InstanceGetPresetCount(VST3InstanceRef instance);

/// Get preset name at index
bool VST3InstanceGetPresetName(
    VST3InstanceRef instance,
    int32_t index,
    char* name,
    int32_t maxLength
);

/// Load preset at index
bool VST3InstanceLoadPreset(
    VST3InstanceRef instance,
    int32_t index
);

// MARK: - Editor/UI

/// Check if plugin has editor
bool VST3InstanceHasEditor(VST3InstanceRef instance);

/// Get preferred editor size
bool VST3InstanceGetEditorSize(
    VST3InstanceRef instance,
    int32_t* width,
    int32_t* height
);

/// Open editor in a native window handle (NSView* on macOS)
bool VST3InstanceOpenEditor(
    VST3InstanceRef instance,
    void* parentView
);

/// Close editor
void VST3InstanceCloseEditor(VST3InstanceRef instance);

/// Resize editor
bool VST3InstanceResizeEditor(
    VST3InstanceRef instance,
    int32_t width,
    int32_t height
);

// MARK: - Utility

/// Get last error message
const char* VST3GetLastError(void);

/// Get VST3 SDK version
const char* VST3GetSDKVersion(void);

#ifdef __cplusplus
}
#endif

#endif /* VST3Host_h */
