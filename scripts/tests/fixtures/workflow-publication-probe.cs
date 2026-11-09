using System;
using System.IO;
using System.Threading;
using System.Threading.Tasks;
using System.Collections.Concurrent;
public static class WorkflowPublicationProbe {
 public static object Run(string directory, Action<string,string> publish) {
  Directory.CreateDirectory(directory); string path=Path.Combine(directory,"state.json");File.WriteAllText(path,"old");
  long missing=0,opens=0,writes=0; var errors=new ConcurrentDictionary<string,int>();int done=0;
  Action<string,Exception> log=(kind,e)=>errors.AddOrUpdate(kind+":"+e.GetType().Name+":"+e.HResult.ToString("X8"),1,(_,v)=>v+1);
  var readers=new Task[4];for(int i=0;i<4;i++)readers[i]=Task.Run(()=>{while(Volatile.Read(ref done)==0){if(!File.Exists(path))Interlocked.Increment(ref missing);try{using var s=File.Open(path,FileMode.Open,FileAccess.Read,FileShare.Read|FileShare.Delete);using var r=new StreamReader(s);string text=r.ReadToEnd();if(text!="old" && !System.Text.RegularExpressions.Regex.IsMatch(text,@"^value-[0-9]+$"))throw new Exception("INCOMPLETE_TEXT");Interlocked.Increment(ref opens);}catch(Exception e){log("read",e);}}});
  try {for(int i=0;i<1000;i++){string temp=path+"."+i+".tmp",backup=temp+".backup";File.WriteAllText(temp,"value-"+i);try{publish(temp,path);Interlocked.Increment(ref writes);}catch(Exception e){log("write",e);}finally{if(File.Exists(path)){if(File.Exists(temp))File.Delete(temp);if(File.Exists(backup))File.Delete(backup);}}}}
  finally{Volatile.Write(ref done,1);Task.WaitAll(readers);}
  return new{missing,opens,writes,errors};
 }
}
