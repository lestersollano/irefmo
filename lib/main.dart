// =============================================================================
// FRIDGE → RECIPES
// A single-file Flutter prototype (Material 3, no state-management packages).
//
// Sections in this file:
//   1. Config constants (API key / base URL / model)
//   2. AI prompts (vision + recipes)
//   3. Theme constants
//   4. Models (FoodItem, Recipe, RecipeResult, ApiException)
//   5. JSON helpers + API layer (two small, editable request builders)
//   6. Shared small widgets
//   7. Screen 1 – Take a snap of your fridge
//   8. Screen 2 – Review items and ingredients
//   9. Screen 3 – Ready to make recipes
//  10. Screen 4 – Recipe detail
// =============================================================================

import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:image_picker/image_picker.dart';

// =============================================================================
// SECTION 1: CONFIG — edit these three lines
// =============================================================================

const String kApiKey = 'sk-0b8c340566ca4a2c99bce80b735681a2';
const String kBaseUrl = 'https://api.deepseek.com';
const String kModel = 'deepseek-flash';

/// Network timeout for every API call.
const Duration kRequestTimeout = Duration(seconds: 90);

/// Image resize settings applied at capture / pick time.
const double kImageMaxSide = 1024;
const int kImageQuality = 80;

// =============================================================================
// SECTION 2: PROMPTS
// =============================================================================

const String kVisionPrompt = r'''
You are a food-inventory assistant for a recipe app. You will receive one or more photos of the inside of a refrigerator (different shelves, door, drawers). Identify the food and drink items visible across ALL the photos.

Rules:
1. Merge duplicates. The same item may appear in several photos or appear several times; list each distinct item only once.
2. Only list items you can actually see. Do not guess what might be hidden behind other items.
3. Use short, generic, recipe-friendly names (e.g. "eggs", "milk", "cheddar cheese", "bell pepper"), not brand names. Keep a brand or flavor only if it matters for cooking (e.g. "coconut milk", "oyster sauce").
4. For packaged items where the label is unreadable, give your best generic guess and set confidence to "low".
5. For leftovers or unlabeled containers, describe them briefly (e.g. "cooked rice (leftover)", "unidentified container") and set confidence to "low".
6. Ignore non-food objects, shelves, and containers themselves.
7. Choose a category for each item from: "produce", "dairy", "meat_seafood", "eggs", "condiments_sauces", "drinks", "leftovers", "packaged_other", "unknown".
8. Set confidence to "high", "medium" or "low".

Respond with ONLY valid JSON, no markdown fences, no commentary, in exactly this shape:

{
  "items": [
    {
      "name": "string",
      "category": "string",
      "confidence": "high | medium | low"
    }
  ],
  "notes": "string (optional: anything unclear, e.g. a blurry photo or a hidden shelf)"
}

If no food is visible, return {"items": [], "notes": "No food detected."}
''';

const String kRecipePrompt = r'''
You are a creative home-cooking assistant for a recipe app. Below this prompt is a JSON list of ingredients detected in the user's fridge. Suggest dishes based on it, in two separate lists.

ASSUMPTIONS
- Salt, pepper, cooking oil, water, and common dried spices and herbs (paprika, cumin, oregano, chili flakes, garlic powder, etc.) are ALWAYS available. Never list them as missing.
- Everything else must come from the ingredient list, or be listed as missing.
- Items with confidence "low" may be misidentified. Prefer recipes that don't depend on them, and never build a "can_make_now" recipe around a low-confidence item.

LIST 1: "can_make_now"
Suggest up to 5 recipes that can be made using ONLY the listed ingredients plus the always-available items. "ingredients_missing" must be an empty array for every recipe in this list. If fewer than 5 sensible dishes exist, return fewer.

LIST 2: "need_to_buy"
Suggest up to 5 recipes that are noticeably better or more varied, but need a small number of extra ingredients. Each recipe must be missing between 1 and 4 ingredients, and those must be cheap and easy to find in a supermarket. Do not repeat recipes from List 1. Base each recipe mainly on what the user already has.

FOR EACH RECIPE
- Give variety: don't suggest five versions of the same dish; mix cooking styles and meal types.
- Make the short description appealing and 1-2 sentences long.
- "ingredients_used" are items from the user's list that the dish uses. Use the exact item names from the input.
- "ingredients_missing" are the extra items to buy (empty for List 1).
- Provide a realistic per-serving estimate for calories (kcal), protein (grams) and fat (grams) as whole numbers.
- Provide clear step-by-step cooking instructions in "steps", one string per step, 4 to 8 steps.
- Keep the dish realistic for a home cook with basic equipment.

OUTPUT FORMAT
Respond with ONLY valid JSON, with no markdown fences and no extra commentary, in exactly this shape:

{
  "can_make_now": [
    {
      "title": "string",
      "short_description": "string",
      "cook_time_minutes": 30,
      "difficulty": "easy | medium | hard",
      "servings": 2,
      "calories": 450,
      "protein_g": 20,
      "fat_g": 15,
      "ingredients_used": ["string"],
      "ingredients_missing": [],
      "steps": ["string"]
    }
  ],
  "need_to_buy": [
    {
      "title": "string",
      "short_description": "string",
      "cook_time_minutes": 30,
      "difficulty": "easy | medium | hard",
      "servings": 2,
      "calories": 450,
      "protein_g": 20,
      "fat_g": 15,
      "ingredients_used": ["string"],
      "ingredients_missing": ["string"],
      "steps": ["string"]
    }
  ]
}

If the ingredient list is empty or has too little to cook anything, return {"can_make_now": [], "need_to_buy": []}.

USER'S INGREDIENT LIST (JSON):
''';

// =============================================================================
// SECTION 3: THEME CONSTANTS
// =============================================================================

const Color kGrey = Color(0xFFD9D9D9);
const Color kLightGrey = Color(0xFFEDEDED);
const Color kFadedText = Color(0x66000000);
const double kRadius = 12.0;

// =============================================================================
// SECTION 4: MODELS
// =============================================================================

/// One detected fridge item. `isDeleted` is a soft-delete flag: deleted rows
/// stay in the list (greyed out + undo) but are excluded from the recipe call.
class FoodItem {
  FoodItem({
    required this.name,
    this.category = 'unknown',
    this.confidence = 'low',
    this.isDeleted = false,
  });

  String name;
  String category;
  String confidence;
  bool isDeleted;

  FoodItem copy() => FoodItem(
    name: name,
    category: category,
    confidence: confidence,
    isDeleted: isDeleted,
  );

  /// Tolerant of missing / wrongly typed fields.
  factory FoodItem.fromJson(Map<String, dynamic> json) {
    return FoodItem(
      name: _asString(json['name'], ''),
      category: _asString(json['category'], 'unknown'),
      confidence: _asString(json['confidence'], 'low'),
      isDeleted: json['isDeleted'] == true,
    );
  }

  /// Shape sent to the recipe prompt.
  Map<String, dynamic> toApiJson() => <String, dynamic>{
    'name': name,
    'category': category,
    'confidence': confidence,
  };
}

class Recipe {
  Recipe({
    required this.title,
    required this.shortDescription,
    required this.cookTimeMinutes,
    required this.difficulty,
    required this.servings,
    required this.calories,
    required this.proteinG,
    required this.fatG,
    required this.ingredientsUsed,
    required this.ingredientsMissing,
    required this.steps,
  });

  final String title;
  final String shortDescription;
  final int cookTimeMinutes;
  final String difficulty;
  final int servings;
  final int calories;
  final int proteinG;
  final int fatG;
  final List<String> ingredientsUsed;
  final List<String> ingredientsMissing;
  final List<String> steps;

  /// Tolerant of missing / wrongly typed fields.
  factory Recipe.fromJson(Map<String, dynamic> json) {
    return Recipe(
      title: _asString(json['title'], 'Untitled dish'),
      shortDescription: _asString(json['short_description'], ''),
      cookTimeMinutes: _asInt(json['cook_time_minutes'], 0),
      difficulty: _asString(json['difficulty'], 'easy'),
      servings: _asInt(json['servings'], 2),
      calories: _asInt(json['calories'], 0),
      proteinG: _asInt(json['protein_g'], 0),
      fatG: _asInt(json['fat_g'], 0),
      ingredientsUsed: _asStringList(json['ingredients_used']),
      ingredientsMissing: _asStringList(json['ingredients_missing']),
      steps: _asStringList(json['steps']),
    );
  }
}

class RecipeResult {
  RecipeResult({required this.canMakeNow, required this.needToBuy});

  final List<Recipe> canMakeNow;
  final List<Recipe> needToBuy;
}

class ApiException implements Exception {
  ApiException(this.message);

  final String message;

  @override
  String toString() => message;
}

// =============================================================================
// SECTION 5: JSON HELPERS + API LAYER
// =============================================================================

String _asString(dynamic value, String fallback) {
  if (value is String && value.trim().isNotEmpty) return value.trim();
  if (value is num || value is bool) return value.toString();
  return fallback;
}

int _asInt(dynamic value, int fallback) {
  if (value is int) return value;
  if (value is num) return value.round();
  if (value is String) {
    final trimmed = value.trim();
    final asInt = int.tryParse(trimmed);
    if (asInt != null) return asInt;
    final asDouble = double.tryParse(trimmed);
    if (asDouble != null) return asDouble.round();
  }
  return fallback;
}

List<String> _asStringList(dynamic value) {
  if (value is List) {
    return value
        .map((e) => e is String ? e.trim() : (e == null ? '' : e.toString()))
        .where((e) => e.isNotEmpty)
        .toList();
  }
  if (value is String && value.trim().isNotEmpty) return <String>[value.trim()];
  return <String>[];
}

/// Strips ```json fences, finds the outermost {...} and jsonDecodes it.
/// Throws [ApiException] with a readable message on failure.
Map<String, dynamic> parseJsonObjectLenient(String raw) {
  var text = raw.trim();
  // Remove markdown fences anywhere in the payload.
  text = text.replaceAll(RegExp(r'```[a-zA-Z]*'), '').replaceAll('```', '');

  final start = text.indexOf('{');
  final end = text.lastIndexOf('}');
  if (start == -1 || end == -1 || end <= start) {
    throw ApiException(
      'The model did not return JSON. Raw response:\n\n${_preview(raw)}',
    );
  }

  final candidate = text.substring(start, end + 1);
  dynamic decoded;
  try {
    decoded = jsonDecode(candidate);
  } catch (_) {
    throw ApiException(
      'Could not decode the model response as JSON.\n\n${_preview(raw)}',
    );
  }

  if (decoded is Map) {
    return decoded.map((k, v) => MapEntry(k.toString(), v));
  }
  throw ApiException('The model returned JSON that is not an object.');
}

String _preview(String s) {
  final trimmed = s.trim();
  return trimmed.length <= 600 ? trimmed : '${trimmed.substring(0, 600)}…';
}

/// ---------------------------------------------------------------------------
/// SINGLE LOW-LEVEL REQUEST HELPER.
/// Everything about the HTTP shape lives here, so if the provider changes its
/// request format you only have to edit this one function.
/// ---------------------------------------------------------------------------
Future<String> _chatCompletion({
  required Object userContent, // String OR List<Map<String,dynamic>>
  required double temperature,
}) async {
  final uri = Uri.parse('$kBaseUrl/chat/completions');
  final body = jsonEncode(<String, dynamic>{
    'model': kModel,
    'temperature': temperature,
    'messages': <Map<String, dynamic>>[
      <String, dynamic>{'role': 'user', 'content': userContent},
    ],
  });

  http.Response response;
  try {
    response = await http
        .post(
          uri,
          headers: const <String, String>{'Content-Type': 'application/json'}
              .copyWithAuth(),
          body: body,
        )
        .timeout(kRequestTimeout);
  } on TimeoutException {
    throw ApiException(
      'The request timed out after ${kRequestTimeout.inSeconds}s. '
      'Check your connection and try again.',
    );
  } catch (e) {
    throw ApiException('Network error: $e');
  }

  if (response.statusCode < 200 || response.statusCode >= 300) {
    var detail = utf8.decode(response.bodyBytes, allowMalformed: true);
    try {
      final decoded = jsonDecode(detail);
      if (decoded is Map &&
          decoded['error'] is Map &&
          decoded['error']['message'] is String) {
        detail = decoded['error']['message'] as String;
      }
    } catch (_) {
      // keep raw body
    }
    throw ApiException('API error ${response.statusCode}: ${_preview(detail)}');
  }

  dynamic decoded;
  try {
    decoded = jsonDecode(utf8.decode(response.bodyBytes));
  } catch (_) {
    throw ApiException('The API response was not valid JSON.');
  }

  final choices = decoded is Map ? decoded['choices'] : null;
  if (choices is! List || choices.isEmpty) {
    throw ApiException('The API returned no choices.');
  }

  final first = choices.first;
  final message = first is Map ? first['message'] : null;
  final content = message is Map ? message['content'] : null;

  if (content is String) return content;
  if (content is List) {
    final buffer = StringBuffer();
    for (final part in content) {
      if (part is Map && part['text'] is String) {
        buffer.write(part['text'] as String);
      }
    }
    if (buffer.isNotEmpty) return buffer.toString();
  }
  throw ApiException('The API returned an empty message.');
}

extension on Map<String, String> {
  Map<String, String> copyWithAuth() => <String, String>{
    ...this,
    'Authorization': 'Bearer $kApiKey',
  };
}

/// ---------------------------------------------------------------------------
/// VISION CALL — one user message, text part first, then one image part per
/// photo. Temperature 0.2.
/// ---------------------------------------------------------------------------
Future<List<FoodItem>> detectFridgeItems(List<Uint8List> photos) async {
  final contentParts = <Map<String, dynamic>>[
    <String, dynamic>{'type': 'text', 'text': kVisionPrompt},
  ];
  for (final bytes in photos) {
    contentParts.add(<String, dynamic>{
      'type': 'image_url',
      'image_url': <String, dynamic>{
        'url': 'data:image/jpeg;base64,${base64Encode(bytes)}',
      },
    });
  }

  final raw = await _chatCompletion(
    userContent: contentParts,
    temperature: 0.2,
  );

  final json = parseJsonObjectLenient(raw);
  final rawItems = json['items'];
  final items = <FoodItem>[];
  if (rawItems is List) {
    for (final entry in rawItems) {
      if (entry is Map) {
        final item = FoodItem.fromJson(
          entry.map((k, v) => MapEntry(k.toString(), v)),
        );
        if (item.name.trim().isNotEmpty) items.add(item);
      }
    }
  }
  return items;
}

/// ---------------------------------------------------------------------------
/// RECIPE CALL — one user message: prompt + "\n" + JSON list of items.
/// Temperature 0.7.
/// ---------------------------------------------------------------------------
Future<RecipeResult> generateRecipes(List<FoodItem> items) async {
  final active = items.where((i) => !i.isDeleted).toList();
  final payload = jsonEncode(active.map((e) => e.toApiJson()).toList());
  final prompt = '$kRecipePrompt\n$payload';

  final raw = await _chatCompletion(userContent: prompt, temperature: 0.7);
  final json = parseJsonObjectLenient(raw);

  return RecipeResult(
    canMakeNow: _parseRecipeList(json['can_make_now']),
    needToBuy: _parseRecipeList(json['need_to_buy']),
  );
}

List<Recipe> _parseRecipeList(dynamic value) {
  if (value is! List) return <Recipe>[];
  final out = <Recipe>[];
  for (final entry in value) {
    if (entry is Map) {
      out.add(Recipe.fromJson(entry.map((k, v) => MapEntry(k.toString(), v))));
    }
  }
  return out;
}

// =============================================================================
// SECTION 6: SHARED WIDGETS
// =============================================================================

class GreyButton extends StatelessWidget {
  const GreyButton({
    super.key,
    this.label,
    this.icon,
    this.onTap,
    this.width,
    this.height = 56,
  });

  final String? label;
  final IconData? icon;
  final VoidCallback? onTap;
  final double? width;
  final double height;

  @override
  Widget build(BuildContext context) {
    final enabled = onTap != null;
    return Opacity(
      opacity: enabled ? 1.0 : 0.45,
      child: Material(
        color: kGrey,
        borderRadius: BorderRadius.circular(kRadius),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: SizedBox(
            width: width,
            height: height,
            child: Center(
              child: label != null
                  ? Text(
                      label!,
                      style: const TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                        color: Colors.black,
                      ),
                    )
                  : Icon(icon, color: Colors.black87),
            ),
          ),
        ),
      ),
    );
  }
}

/// Dashed rounded border used by the "+" tile on Screen 1.
class DashedRoundedBorderPainter extends CustomPainter {
  DashedRoundedBorderPainter({
    this.color = const Color(0x66000000),
    this.radius = kRadius,
    this.strokeWidth = 1.5,
    this.dashLength = 6,
    this.gapLength = 4,
  });

  final Color color;
  final double radius;
  final double strokeWidth;
  final double dashLength;
  final double gapLength;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = strokeWidth;

    final rrect = RRect.fromRectAndRadius(
      Rect.fromLTWH(
        strokeWidth / 2,
        strokeWidth / 2,
        math.max(size.width - strokeWidth, 0),
        math.max(size.height - strokeWidth, 0),
      ),
      Radius.circular(radius),
    );

    final path = Path()..addRRect(rrect);
    for (final metric in path.computeMetrics()) {
      double distance = 0;
      while (distance < metric.length) {
        final end = math.min(distance + dashLength, metric.length);
        canvas.drawPath(metric.extractPath(distance, end), paint);
        distance = end + gapLength;
      }
    }
  }

  @override
  bool shouldRepaint(covariant DashedRoundedBorderPainter oldDelegate) =>
      oldDelegate.color != color ||
      oldDelegate.radius != radius ||
      oldDelegate.strokeWidth != strokeWidth ||
      oldDelegate.dashLength != dashLength ||
      oldDelegate.gapLength != gapLength;
}

Future<void> showErrorDialog(BuildContext context, String message) {
  return showDialog<void>(
    context: context,
    builder: (ctx) => AlertDialog(
      backgroundColor: Colors.white,
      title: const Text('Something went wrong'),
      content: SingleChildScrollView(child: Text(message)),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(ctx).pop(),
          child: const Text('OK', style: TextStyle(color: Colors.black)),
        ),
      ],
    ),
  );
}

// =============================================================================
// SECTION 7: SCREEN 1 — Take a snap of your fridge
// =============================================================================

class FridgeSnapScreen extends StatefulWidget {
  const FridgeSnapScreen({super.key});

  @override
  State<FridgeSnapScreen> createState() => _FridgeSnapScreenState();
}

class _FridgeSnapScreenState extends State<FridgeSnapScreen> {
  final ImagePicker _picker = ImagePicker();
  final List<Uint8List> _photos = <Uint8List>[];
  bool _busy = false;

  // ---------------------------------------------------------------------------
  // Image capture / pick
  // ---------------------------------------------------------------------------

  Future<void> _addFromGallery() async {
    if (_busy) return;
    try {
      final files = await _picker.pickMultiImage(
        maxWidth: kImageMaxSide,
        maxHeight: kImageMaxSide,
        imageQuality: kImageQuality,
      );
      if (files.isEmpty) return;
      final bytesList = <Uint8List>[];
      for (final file in files) {
        bytesList.add(await file.readAsBytes());
      }
      if (!mounted) return;
      setState(() => _photos.addAll(bytesList));
    } catch (e) {
      if (!mounted) return;
      await showErrorDialog(context, 'Could not open the gallery.\n$e');
    }
  }

  Future<void> _addFromCamera() async {
    if (_busy) return;
    try {
      final file = await _picker.pickImage(
        source: ImageSource.camera,
        maxWidth: kImageMaxSide,
        maxHeight: kImageMaxSide,
        imageQuality: kImageQuality,
      );
      if (file == null) return;
      final bytes = await file.readAsBytes();
      if (!mounted) return;
      setState(() => _photos.add(bytes));
    } catch (e) {
      if (!mounted) return;
      await showErrorDialog(context, 'Could not open the camera.\n$e');
    }
  }

  // ---------------------------------------------------------------------------
  // Vision call → Screen 2
  // ---------------------------------------------------------------------------

  Future<void> _next() async {
    if (_photos.isEmpty || _busy) return;
    setState(() => _busy = true);
    try {
      final items = await detectFridgeItems(_photos);
      if (!mounted) return;
      setState(() => _busy = false);

      if (items.isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('No food detected. Try another photo.')),
        );
        return;
      }

      await Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => ReviewItemsScreen(items: items),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      setState(() => _busy = false);
      await showErrorDialog(
        context,
        e is ApiException ? e.message : 'Unexpected error: $e',
      );
    }
  }

  // ---------------------------------------------------------------------------
  // Build
  // ---------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.white,
      body: SafeArea(
        child: Stack(
          children: <Widget>[
            Column(
              children: <Widget>[
                const SizedBox(height: 24),
                const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 24),
                  child: Text(
                    'Take a snap of your fridge',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: 22,
                      fontWeight: FontWeight.w600,
                      color: Colors.black,
                    ),
                  ),
                ),
                const SizedBox(height: 20),
                Expanded(
                  child: GridView.builder(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    itemCount: _photos.length + 1,
                    gridDelegate:
                        const SliverGridDelegateWithFixedCrossAxisCount(
                          crossAxisCount: 2,
                          crossAxisSpacing: 12,
                          mainAxisSpacing: 12,
                          childAspectRatio: 1,
                        ),
                    itemBuilder: (context, index) {
                      if (index < _photos.length) {
                        return _photoTile(_photos[index]);
                      }
                      return _addTile();
                    },
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
                  child: Row(
                    children: <Widget>[
                      GreyButton(
                        icon: Icons.photo_camera_outlined,
                        width: 56,
                        onTap: _busy ? null : _addFromCamera,
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: GreyButton(
                          label: 'Next',
                          onTap: (_photos.isEmpty || _busy) ? null : _next,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            if (_busy)
              const Positioned.fill(
                child: ColoredBox(
                  color: Color(0xF2FFFFFF),
                  child: Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: <Widget>[
                        CircularProgressIndicator(color: Colors.black),
                        SizedBox(height: 16),
                        Text(
                          'Looking at your fridge...',
                          style: TextStyle(fontSize: 16, color: Colors.black),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _photoTile(Uint8List bytes) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(kRadius),
      child: Image.memory(bytes, fit: BoxFit.cover, gaplessPlayback: true),
    );
  }

  Widget _addTile() {
    return Material(
      color: Colors.white,
      borderRadius: BorderRadius.circular(kRadius),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: _busy ? null : _addFromGallery,
        child: CustomPaint(
          painter: DashedRoundedBorderPainter(color: const Color(0x88000000)),
          child: const Center(
            child: Icon(Icons.add, size: 34, color: Colors.black54),
          ),
        ),
      ),
    );
  }
}

// =============================================================================
// SECTION 8: SCREEN 2 — Review items and ingredients
// =============================================================================

class ReviewItemsScreen extends StatefulWidget {
  const ReviewItemsScreen({super.key, required this.items});

  final List<FoodItem> items;

  @override
  State<ReviewItemsScreen> createState() => _ReviewItemsScreenState();
}

class _ReviewItemsScreenState extends State<ReviewItemsScreen> {
  late final List<FoodItem> _items;

  @override
  void initState() {
    super.initState();
    _items = widget.items.map((e) => e.copy()).toList();
  }

  int get _activeCount => _items.where((e) => !e.isDeleted).length;

  Future<void> _renameItem(int index) async {
    final controller = TextEditingController(text: _items[index].name);
    final result = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: Colors.white,
        title: const Text('Rename item'),
        content: TextField(
          controller: controller,
          autofocus: true,
          textCapitalization: TextCapitalization.sentences,
          decoration: const InputDecoration(hintText: 'Item name'),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text(
              'Cancel',
              style: TextStyle(color: Colors.black54),
            ),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(controller.text.trim()),
            child: const Text('Save', style: TextStyle(color: Colors.black)),
          ),
        ],
      ),
    );
    controller.dispose();

    if (result != null && result.isNotEmpty) {
      setState(() => _items[index].name = result);
    }
  }

  void _findRecipes() {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) =>
            RecipesScreen(items: _items.map((e) => e.copy()).toList()),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.white,
      appBar: AppBar(
        backgroundColor: Colors.white,
        foregroundColor: Colors.black,
        elevation: 0,
        scrolledUnderElevation: 0,
        centerTitle: true,
        title: const Text(
          'Review items and ingredients',
          style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
        ),
      ),
      body: SafeArea(
        child: Column(
          children: <Widget>[
            Expanded(
              child: _items.isEmpty
                  ? const Center(
                      child: Text(
                        'No items detected.',
                        style: TextStyle(color: kFadedText),
                      ),
                    )
                  : ListView.builder(
                      padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
                      itemCount: _items.length,
                      itemBuilder: (context, index) =>
                          _buildRow(context, index),
                    ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
              child: GreyButton(
                label: 'Find Recipes',
                onTap: _activeCount == 0 ? null : _findRecipes,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildRow(BuildContext context, int index) {
    final item = _items[index];
    final deleted = item.isDeleted;

    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      constraints: const BoxConstraints(minHeight: 60),
      decoration: BoxDecoration(
        color: deleted ? const Color(0xFFF4F4F4) : kLightGrey,
        borderRadius: BorderRadius.circular(kRadius),
      ),
      child: Row(
        children: <Widget>[
          Expanded(
            child: Text(
              item.name,
              style: TextStyle(
                fontSize: 16,
                color: deleted ? kFadedText : Colors.black,
                decoration: deleted ? TextDecoration.lineThrough : null,
                decorationColor: kFadedText,
              ),
            ),
          ),
          if (!deleted) ...<Widget>[
            IconButton(
              tooltip: 'Rename',
              icon: const Icon(Icons.edit_outlined, size: 20),
              color: Colors.black87,
              onPressed: () => _renameItem(index),
            ),
            IconButton(
              tooltip: 'Remove',
              icon: const Icon(Icons.delete_outline, size: 20),
              color: Colors.black87,
              onPressed: () => setState(() => _items[index].isDeleted = true),
            ),
          ] else
            IconButton(
              tooltip: 'Undo',
              icon: const Icon(Icons.undo, size: 20),
              color: Colors.black87,
              onPressed: () => setState(() => _items[index].isDeleted = false),
            ),
        ],
      ),
    );
  }
}

// =============================================================================
// SECTION 9: SCREEN 3 — Ready to make recipes
// =============================================================================

class RecipesScreen extends StatefulWidget {
  const RecipesScreen({super.key, required this.items});

  final List<FoodItem> items;

  @override
  State<RecipesScreen> createState() => _RecipesScreenState();
}

class _RecipesScreenState extends State<RecipesScreen> {
  bool _loading = true;
  String? _error;
  List<Recipe> _canMakeNow = <Recipe>[];
  List<Recipe> _needToBuy = <Recipe>[];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final result = await generateRecipes(widget.items);
      if (!mounted) return;
      setState(() {
        _canMakeNow = result.canMakeNow;
        _needToBuy = result.needToBuy;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e is ApiException ? e.message : 'Unexpected error: $e';
        _loading = false;
      });
    }
  }

  void _openRecipe(Recipe recipe) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => RecipeDetailScreen(recipe: recipe),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.white,
      appBar: AppBar(
        backgroundColor: Colors.white,
        foregroundColor: Colors.black,
        elevation: 0,
        scrolledUnderElevation: 0,
      ),
      body: SafeArea(child: _buildBody()),
    );
  }

  Widget _buildBody() {
    if (_loading) {
      return const Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            CircularProgressIndicator(color: Colors.black),
            SizedBox(height: 16),
            Text(
              'Generating recipes...',
              style: TextStyle(fontSize: 16, color: Colors.black),
            ),
          ],
        ),
      );
    }

    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              const Icon(Icons.error_outline, size: 40, color: Colors.black45),
              const SizedBox(height: 12),
              Text(
                _error!,
                textAlign: TextAlign.center,
                style: const TextStyle(fontSize: 14, color: Colors.black87),
              ),
              const SizedBox(height: 20),
              SizedBox(
                width: 160,
                child: GreyButton(label: 'Retry', onTap: _load),
              ),
            ],
          ),
        ),
      );
    }

    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          _buildSection('Ready to make recipes', _canMakeNow),
          _buildSection('Recipes with missing ingredients', _needToBuy),
          const SizedBox(height: 24),
        ],
      ),
    );
  }

  Widget _buildSection(String title, List<Recipe> recipes) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 20, 16, 12),
          child: Text(
            title,
            style: const TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.w600,
              color: Colors.black,
            ),
          ),
        ),
        if (recipes.isEmpty)
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 16),
            child: Text(
              'Nothing to show here.',
              style: TextStyle(fontSize: 14, color: kFadedText),
            ),
          )
        else
          SizedBox(
            height: 268,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 16),
              itemCount: recipes.length,
              separatorBuilder: (_, __) => const SizedBox(width: 12),
              itemBuilder: (context, index) {
                final recipe = recipes[index];
                return RecipeCard(
                  recipe: recipe,
                  onTap: () => _openRecipe(recipe),
                );
              },
            ),
          ),
      ],
    );
  }
}

class RecipeCard extends StatelessWidget {
  const RecipeCard({super.key, required this.recipe, required this.onTap});

  final Recipe recipe;
  final VoidCallback onTap;

  static const TextStyle _metaStyle = TextStyle(
    fontSize: 11,
    color: Colors.black87,
  );

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 220,
      child: Material(
        color: kLightGrey,
        borderRadius: BorderRadius.circular(kRadius),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Container(
                  height: 84,
                  width: double.infinity,
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: const Icon(
                    Icons.restaurant,
                    size: 38,
                    color: Colors.black26,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  recipe.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                    color: Colors.black,
                  ),
                ),
                const SizedBox(height: 4),
                Wrap(
                  spacing: 8,
                  runSpacing: 2,
                  children: <Widget>[
                    Text('${recipe.calories} kcal', style: _metaStyle),
                    Text('${recipe.proteinG}g protein', style: _metaStyle),
                    Text('${recipe.fatG}g fats', style: _metaStyle),
                  ],
                ),
                if (recipe.ingredientsMissing.isNotEmpty) ...<Widget>[
                  const SizedBox(height: 4),
                  Text(
                    'Missing: ${recipe.ingredientsMissing.join(', ')}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 11,
                      fontStyle: FontStyle.italic,
                      color: Colors.black87,
                    ),
                  ),
                ],
                const SizedBox(height: 6),
                Expanded(
                  child: Text(
                    recipe.shortDescription,
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 12,
                      height: 1.3,
                      color: Colors.black87,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// =============================================================================
// SECTION 10: SCREEN 4 — Recipe detail
// =============================================================================

class RecipeDetailScreen extends StatelessWidget {
  const RecipeDetailScreen({super.key, required this.recipe});

  final Recipe recipe;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.white,
      appBar: AppBar(
        backgroundColor: Colors.white,
        foregroundColor: Colors.black,
        elevation: 0,
        scrolledUnderElevation: 0,
        centerTitle: true,
        title: Text(
          recipe.title,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
        ),
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
          children: <Widget>[
            // Large grey image placeholder.
            Container(
              height: 180,
              decoration: BoxDecoration(
                color: kGrey,
                borderRadius: BorderRadius.circular(kRadius),
              ),
              child: const Center(
                child: Icon(Icons.restaurant, size: 64, color: Colors.white),
              ),
            ),
            const SizedBox(height: 16),

            // Nutrition bar.
            Container(
              padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 8),
              decoration: BoxDecoration(
                color: kLightGrey,
                borderRadius: BorderRadius.circular(kRadius),
              ),
              child: Row(
                children: <Widget>[
                  Expanded(
                    child: Text(
                      '${recipe.calories} kcal',
                      textAlign: TextAlign.center,
                      style: const TextStyle(fontSize: 14, color: Colors.black),
                    ),
                  ),
                  Expanded(
                    child: Text(
                      '${recipe.proteinG}g protein',
                      textAlign: TextAlign.center,
                      style: const TextStyle(fontSize: 14, color: Colors.black),
                    ),
                  ),
                  Expanded(
                    child: Text(
                      '${recipe.fatG}g fats',
                      textAlign: TextAlign.center,
                      style: const TextStyle(fontSize: 14, color: Colors.black),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 12),

            // Meta line (time / difficulty / servings).
            Text(
              '${recipe.cookTimeMinutes} min  ·  ${recipe.difficulty}  ·  '
              '${recipe.servings} serving${recipe.servings == 1 ? '' : 's'}',
              style: const TextStyle(fontSize: 13, color: kFadedText),
            ),
            const SizedBox(height: 16),

            // Full description.
            Text(
              recipe.shortDescription,
              style: const TextStyle(
                fontSize: 15,
                height: 1.4,
                color: Colors.black87,
              ),
            ),
            const SizedBox(height: 24),

            // Ingredients.
            const Text(
              'Ingredients',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 8),
            ...recipe.ingredientsUsed.map(
              (name) => _ingredientRow(name, have: true),
            ),
            if (recipe.ingredientsMissing.isNotEmpty) ...<Widget>[
              const SizedBox(height: 12),
              const Text(
                'Missing ingredients',
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                  color: Colors.black54,
                ),
              ),
              const SizedBox(height: 6),
              ...recipe.ingredientsMissing.map(
                (name) => _ingredientRow(name, have: false),
              ),
            ],
            const SizedBox(height: 24),

            // Steps.
            const Text(
              'Steps',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 8),
            ...List<Widget>.generate(recipe.steps.length, (index) {
              return _stepTile(context, index, recipe.steps[index]);
            }),
          ],
        ),
      ),
    );
  }

  Widget _ingredientRow(String name, {required bool have}) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Icon(
            have ? Icons.check_circle_outline : Icons.shopping_basket_outlined,
            size: 18,
            color: have ? Colors.black87 : Colors.black45,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              have ? name : '$name (missing)',
              style: TextStyle(
                fontSize: 14,
                color: have ? Colors.black87 : Colors.black54,
                fontStyle: have ? FontStyle.normal : FontStyle.italic,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _stepTile(BuildContext context, int index, String text) {
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      decoration: BoxDecoration(
        color: kLightGrey,
        borderRadius: BorderRadius.circular(kRadius),
      ),
      clipBehavior: Clip.antiAlias,
      child: Theme(
        data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
        child: ExpansionTile(
          tilePadding: const EdgeInsets.symmetric(horizontal: 16),
          childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
          expandedCrossAxisAlignment: CrossAxisAlignment.start,
          iconColor: Colors.black87,
          collapsedIconColor: Colors.black54,
          title: Text(
            'Step ${index + 1}',
            style: const TextStyle(
              fontSize: 15,
              fontWeight: FontWeight.w600,
              color: Colors.black,
            ),
          ),
          children: <Widget>[
            Align(
              alignment: Alignment.centerLeft,
              child: Text(
                text,
                style: const TextStyle(
                  fontSize: 14,
                  height: 1.4,
                  color: Colors.black87,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// =============================================================================
// APP ROOT
// =============================================================================

void main() {
  runApp(const FridgeApp());
}

class FridgeApp extends StatelessWidget {
  const FridgeApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Fridge to Recipes',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        scaffoldBackgroundColor: Colors.white,
        colorScheme: ColorScheme.fromSeed(
          seedColor: Colors.black,
          brightness: Brightness.light,
        ),
        appBarTheme: const AppBarTheme(
          backgroundColor: Colors.white,
          surfaceTintColor: Colors.white,
        ),
        snackBarTheme: const SnackBarThemeData(
          backgroundColor: Colors.black87,
          contentTextStyle: TextStyle(color: Colors.white),
        ),
      ),
      home: const FridgeSnapScreen(),
    );
  }
}
