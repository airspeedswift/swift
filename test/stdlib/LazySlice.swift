// RUN: rm -rf %t ; mkdir -p %t
// RUN: %target-build-swift %s -o %t/a.out3 -swift-version 3 && %target-run %t/a.out3
// REQUIRES: executable_test

import StdlibUnittest

var tests = TestSuite("LazySlice")

tests.test("CommuteLazyness") {
  let a = [1,2,3].lazy
  let b = a[...]
  var c = b.filter { $0 == 0 }
  expectType(LazyFilterCollection<Array<Int>.SubSequence>.self, &c)  
  
  let d = sequence(first: 0) { $0 + 1 }.lazy
  let e = d.dropFirst()
  var f = e.filter { $0 == 0 }
  expectType(LazyFilterSequence<UnfoldSequence<Int, (Optional<Swift.Int>, Bool)>.SubSequence>.self, &f)
  
  let h = (0..<5).lazy
  let i = h.dropFirst()
  var j = i.filter { $0 == 0 }
  expectType(LazyFilterCollection<Range<Int>.SubSequence>.self, &j)

  let k = "abc".lazy
  let l = k[...]
  var m = l.filter { $0 == "z" }
  expectType(LazyFilterCollection<Substring>.self, &m)

  let n = [1,2,3].reversed().lazy
  let o = n[...]
  var p = o.filter { $0 == 0 }
  expectType(LazyFilterCollection<Slice<ReversedCollection<Array<Int>>>>.self, &p)
}

runAllTests()
