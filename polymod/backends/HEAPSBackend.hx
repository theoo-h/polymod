package polymod.backends;

import haxe.exceptions.NotImplementedException;
import hxd.File;
import haxe.io.Bytes;
import haxe.xml.Fast;
import haxe.xml.Printer;
import polymod.Polymod;
import polymod.Polymod.PolymodError;
import polymod.Polymod.FrameworkParams;
import polymod.util.Util;
import polymod.backends.PolymodAssetLibrary;
import polymod.backends.PolymodAssets.PolymodAssetType;
using StringTools;

#if unifill
import unifill.Unifill;
#end
#if heaps
import hxd.Res;
import hxd.res.Any;
import hxd.res.Loader;
import hxd.fs.FileEntry;
import hxd.fs.FileSystem;
import hxd.fs.LoadedBitmap;
import hxd.fs.LocalFileSystem;
import hxd.fs.BytesFileSystem.BytesFileEntry;
#end

#if !heaps
class HEAPSBackend extends StubBackend
{
	public function new()
	{
		super();
		Polymod.error(FAILED_CREATE_BACKEND, "HEAPSBackend requires the heaps library, did you forget to install it?");
	}
}
#else
class HEAPSBackend implements IBackend
{
	public static var defaultLoader:Loader = null;

	private static function getDefaultLoader()
	{
		if (defaultLoader == null)
		{
			var loader = Res.loader;
			if (Std.isOfType(loader, HEAPSModLoader) == false)
			{
				defaultLoader = loader;
			}
		}
		return defaultLoader;
	}

	private static function restoreDefaultLoader()
	{
		if (defaultLoader != null)
		{
			Res.loader = defaultLoader;
		}
	}

	public var polymodLibrary:PolymodAssetLibrary;
	public var modLoader(default, null):HEAPSModLoader;
	public var fallback(default, null):Loader;

	var fallbackFileList:Array<String>;

	public function new()
	{
	}

	public function init(?params:FrameworkParams):Bool
	{
		fallback = getDefaultLoader();
		modLoader = new HEAPSModLoader(this);
		Res.loader = modLoader;

		fallbackFileList = buildFallbackFileList();

		return true;
	}

	public function destroy()
	{
		if (modLoader != null)
		{
			modLoader.cleanCache();
			modLoader.destroy();
		}

		if (defaultLoader != null)
		{
			// clear fallback ig
			defaultLoader.cleanCache();
		}

		restoreDefaultLoader();

		modLoader = null;
		fallback = null;
		fallbackFileList = null;
		polymodLibrary = null;
	}

	public function exists(id:String):Bool
	{
		return modLoader.exists(id);
	}

	public function getBytes(id:String):Bytes
	{
		return modLoader.load(id).entry.getBytes();
	}

	public function getText(id:String):String
	{
		return modLoader.loadText(id).toText();
	}

	public function getPath(id:String):String
	{
		var p = polymodLibrary;

		if (p.check(id))
		{
			var modPath = p.file(id);
			if (modPath != null && modPath != '')
				return modPath;
		}

		return id;
	}

	public function list(type:PolymodAssetType = null):Array<String>
	{
		var p = polymodLibrary;
		var items:Array<String> = [];

		var addItem = (path:String) ->
		{
			if (items.indexOf(path) == -1)
			{
				items.push(path);
			}
		};

		var modFiles = (p.typeLibraries != null) ? p.typeLibraries.get('default') : null;
		if (modFiles != null)
		{
			for (id in modFiles)
			{
				if (id.startsWith(PolymodConfig.appendFolder) || id.startsWith(PolymodConfig.mergeFolder))
					continue;
				
				if (type == null || p.check(id, type))
				{
					addItem(id);
				}
			}
		}

		// base
		if (fallbackFileList != null)
		{
			for (id in fallbackFileList)
			{
				if (type != null && type != PolymodAssetType.BYTES)
				{
					var ext = '';
					var doti = Util.uLastIndexOf(id, '.');
					if (doti != -1)
						ext = id.substring(doti + 1);

					var assetType = p.getExtensionType(ext);
					if (assetType != type && assetType != PolymodAssetType.BYTES)
						continue;
				}

				addItem(id);
			}
		}

		return items;
	}

	function buildFallbackFileList():Array<String>
	{
		var result:Array<String> = [];

		if (fallback == null)
			return result;

		try
		{
			walkFileEntry(fallback.fs.getRoot(), '', result);
		}
		catch (e:Dynamic)
		{
			if (PolymodConfig.debug)
				trace('HEAPSBackend: could not enumerate base game assets ($e), falling back to modded assets only.');
		}

		return result;
	}

	function walkFileEntry(entry:FileEntry, currentPath:String, result:Array<String>):Void
	{
		for (child in entry)
		{
			var childPath = (currentPath == '') ? child.name : currentPath + '/' + child.name;

			var isDir = false;
			try
			{
				isDir = child.isDirectory;
			}
			catch (e:Dynamic)
			{
				isDir = false;
			}

			if (isDir)
			{
				walkFileEntry(child, childPath, result);
			}
			else
			{
				result.push(childPath);
			}
		}
	}

	public function clearCache()
	{
		if (modLoader != null)
		{
			modLoader.cleanCache();
		}
		if (defaultLoader != null)
		{
			defaultLoader.cleanCache();
		}
	}

	public function stripAssetsPrefix(id:String):String
	{
		return id;
	}
}

class HEAPSModLoader extends Loader
{
	var b:HEAPSBackend;
	var p:PolymodAssetLibrary;
	var fallback:Loader;
	var hasFallback:Bool;

	public function new(backend:HEAPSBackend)
	{
		b = backend;
		p = b.polymodLibrary;
		fallback = b.fallback;
		hasFallback = fallback != null;
		var fileSystem = new ModFileSystem(p);
		super(fileSystem);
	}

	public function destroy()
	{
		b = null;
		p = null;
		fallback = null;
	}

	public override function exists(path:String):Bool
	{
		var e = p.check(path);
		if (!e && hasFallback)
			return fallback.exists(path);
		return e;
	}

	public override function load(path:String):Any
	{
		if (p.getExtensionType(Util.uExtension(path)) == TEXT)
		{
			return loadText(path);
		}
		return loadBytes(path);
	}

	private function loadBytes(path:String):Any
	{
		var e = p.check(path);

		if (!e && hasFallback)
		{
			var result = fallback.load(path);
			return result;
		}
		return super.load(path);
	}

	public function loadText(path:String):Any
	{
		var modText:String = null;

		if (p.check(path))
		{
			modText = loadBytes(path).toText();
		}
		else if (hasFallback)
		{
			modText = fallback.load(path).toText();
		}

		if (modText != null)
		{
			modText = p.mergeAndAppendText(path, modText);
		}

		if (modText == null)
		{
			modText = '';
		}

		return new Any(this, new BytesFileEntry(path, Bytes.ofString(modText)));
	}
}

class ModFileEntry extends BytesFileEntry
{
	var fullFilePath:String;
	var fs:ModFileSystem;
	var p:PolymodAssetLibrary;
	var b:HEAPSBackend;
	var inited:Bool = false;

	public function new(path:String, bytes:Bytes, fs:ModFileSystem, fullFilePath:String)
	{
		this.fullFilePath = fullFilePath;
		this.fs = fs;
		p = fs.p;
		b = cast fs.b;
		super(path, bytes);
	}

	public static function tryGetFallbackEntry(loader:Loader, path:String):Null<FileEntry>
	{
		if (loader == null)
			return null;

		try
		{
			return loader.fs.get(path);
		}
		catch (e:Dynamic)
		{
			return null;
		}
	}

	private function isPathADirectory(str:String):Bool
	{
		if (p.fileSystem.exists(str) && p.fileSystem.isDirectory(str))
			return true;

		var entry = tryGetFallbackEntry(b.fallback, str);
		if (entry != null && entry.isDirectory)
			return true;

		return false;
	}

	public override function iterator():hxd.impl.ArrayIterator<FileEntry>
	{
		var arr:Array<FileEntry> = [];

		var otherList = [];
		var fallbackEntry = tryGetFallbackEntry(b.fallback, fullFilePath);
		if (fallbackEntry != null)
		{
			for (otherEntry in fallbackEntry.iterator())
			{
				otherList.push(otherEntry);
			}
		}

		var isDir = isPathADirectory(path);
		var dirPath = isDir ? path : Util.uPathPop(fullFilePath);

		var itemPaths = [];
		for (id in p.type.keys())
		{
			if (id.indexOf(dirPath) != 0)
				continue;
			if (id.indexOf(PolymodConfig.appendFolder) == 0 || id.indexOf(PolymodConfig.mergeFolder) == 0)
				continue;
			if (p.ignoredFiles.indexOf(id) != -1)
				continue;
			if (p.fileSystem.isDirectory(id))
				continue;
			arr.push(new ModFileEntry(id, null, fs, id));
			itemPaths.push(id);
		}

		for (otherEntry in otherList)
		{
			if (itemPaths.indexOf(otherEntry.path) == -1)
			{
				var otherPath = otherEntry.path;
				var nextPath = Util.pathJoin(fullFilePath, otherPath);
				arr.push(new ModFileEntry(otherPath, null, fs, nextPath));
			}
		}

		return new hxd.impl.ArrayIterator(arr);
	}

	public override function get(name:String):FileEntry
	{
		var nextPath = Util.pathJoin(fullFilePath, name);
		return new ModFileEntry(name, null, fs, nextPath);
	}

	private inline function initBytes()
	{
		if (inited == false && bytes == null)
		{
			resolveBytes();
			inited = true;
		}
	}

	private function resolveBytes()
	{
		var file = p.file(path);

		if (file != '' && p.fileSystem.exists(file) && !p.fileSystem.isDirectory(file))
		{
			bytes = p.fileSystem.getFileBytes(file);
			return;
		}

		var entry = tryGetFallbackEntry(b.fallback, path);
		if (entry != null && !entry.isDirectory)
		{
			bytes = entry.getBytes();
			return;
		}

		bytes = null;
	}

	override function getSign():Int
	{
		initBytes();
		return super.getSign();
	}

	override function getBytes():Bytes
	{
		initBytes();
		return super.getBytes();
	}

	override function readBytes(out:Bytes, outPos:Int, pos:Int, size:Int)
	{
		initBytes();
		return super.readBytes(out, outPos, pos, size);
	}

	override function loadBitmap(onLoaded:LoadedBitmap->Void):Void
	{
		initBytes();
		return super.loadBitmap(onLoaded);
	}

	override function get_size()
	{
		initBytes();
		return super.get_size();
	}

	override function get_isDirectory():Bool
	{
		initBytes();
		return super.get_isDirectory();
	}
}

class ModFileSystem implements FileSystem
{
	public var p:PolymodAssetLibrary;
	public var b:HEAPSBackend;

	public function new(polymodAssetLibrary:PolymodAssetLibrary)
	{
		p = polymodAssetLibrary;
		b = cast p.backend;
	}

	public function delete(path:String):Bool
	{
		throw new NotImplementedException();
	}

	public function getRoot():FileEntry
	{
		return new ModFileEntry('', null, this, '');
	}

	public function get(path:String):FileEntry
	{
		var file = p.file(path);

		if (file != '' && p.fileSystem.exists(file) && !p.fileSystem.isDirectory(file))
		{
			var bytes = p.fileSystem.getFileBytes(file);
			if (bytes != null)
			{
				return new ModFileEntry(path, bytes, this, path);
			}
		}

		var fallbackEntry = ModFileEntry.tryGetFallbackEntry(b.fallback, path);
		if (fallbackEntry != null)
		{
			return fallbackEntry;
		}

		return new ModFileEntry(path, null, this, path);
	}

	public function exists(path:String):Bool
	{
		return b.modLoader.exists(path);
	}

	public function dispose():Void
	{
		p = null;
		b = null;
	}

	public function dir(path:String):Array<FileEntry>
	{
		var names = p.fileSystem.readDirectory(path);
		var arr = [];
		for (name in names)
		{
			arr.push(get(name));
		}
		return arr;
	}
}
#end
