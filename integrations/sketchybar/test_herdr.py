import unittest
from herdr import properties

class StatusTests(unittest.TestCase):
    def state(self, **changes):
        return dict(schemaVersion=1, writtenAt=1000, isRunning=True, mode='attention', attentionCount=3, summary='Connected', **changes)

    def test_modes(self):
        state = self.state()
        self.assertIn('label=Herdr 3', properties(state, 1000))
        state.update(mode='clear', attentionCount=0)
        self.assertIn('label=Herdr', properties(state, 1000))
        self.assertIn('icon.color=0xff94e2d5', properties(state, 1000))
        state.update(mode='disconnected')
        self.assertIn('icon.color=0xff6c7086', properties(state, 1000))

    def test_invalid_or_dead_is_dim(self):
        cases = [None, [], {}, self.state() | {'isRunning':False}]
        for field,value in [('writtenAt', 800), ('writtenAt', 1010), ('writtenAt', float('nan')), ('writtenAt', True), ('writtenAt', 10**1000), ('attentionCount',-1), ('attentionCount',True), ('attentionCount', '3'), ('schemaVersion',2), ('schemaVersion',True), ('mode','bad'), ('isRunning',1)]:
            cases.append(self.state() | {field:value})
        for state in cases:
            with self.subTest(state=state):
                self.assertIn('icon.color=0xff6c7086', properties(state, 1000))
                self.assertIn('label=Herdr', properties(state, 1000))

    def test_summary_cannot_become_a_command_or_property(self):
        state = self.state() | {'summary': '$(touch /tmp/pwn)\n--remove all'}
        self.assertEqual(properties(state, 1000), properties(self.state(), 1000))

if __name__ == '__main__': unittest.main()
