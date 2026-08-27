/**
 * 连连看纯逻辑回归。
 *
 * 覆盖：路径规则（0/1/2 拐弯、外围绕行、被挡住不可连）、点选与消除、
 * 死局检测与洗牌自救、提示、胜利、计分，以及「重开换牌但仍可复现」。
 */
import { describe, expect, it } from 'vitest';
import {
  DEFAULT_LEVEL,
  LEVELS,
  boardForStage,
  clearHint,
  clearPath,
  connectionPath,
  createInitialState,
  dealSeed,
  ensurePlayable,
  findAvailableMove,
  findPath,
  hint,
  levelAt,
  restart,
  scoreFor,
  selectTile,
  shuffleBoard,
} from './logic';
import type { OnetState } from './logic';

/**
 * 用字符画搭一个测试棋盘：'.' 为空位，其余字符按字符码当作图案 id。
 * 例如 ['ab', '..'] 是 2×2 棋盘，左上 a、右上 b、下面两格为空。
 */
function board(rows: readonly string[]): OnetState {
  const cols = (rows[0] as string).length;
  const tiles: (number | null)[] = [];
  for (const row of rows) {
    for (const char of row) tiles.push(char === '.' ? null : char.charCodeAt(0));
  }
  const remaining = tiles.filter((tile) => tile !== null).length;
  return {
    seed: 'test',
    round: 0,
    level: 0,
    rows: rows.length,
    cols,
    symbols: 26,
    tiles,
    selected: null,
    lastPath: null,
    hintPair: null,
    remaining,
    moves: 0,
    hints: 0,
    shuffles: 0,
    status: 'idle',
  };
}

/** 按 (x, y) 取下标。 */
function at(state: OnetState, x: number, y: number): number {
  return y * state.cols + x;
}

describe('连连看：路径规则', () => {
  it('直线相邻的两张牌 0 拐弯可连', () => {
    const state = board(['aa']);
    const path = connectionPath(state, at(state, 0, 0), at(state, 1, 0));
    expect(path).not.toBeNull();
    expect(path).toHaveLength(2);
  });

  it('同一行隔着空格仍可直连', () => {
    const state = board(['a..a']);
    expect(connectionPath(state, at(state, 0, 0), at(state, 3, 0))).not.toBeNull();
  });

  it('直线被挡且外围绕不回来时不可连', () => {
    // 中间一行被 x/b 挡死，两张 a 上下也被 x 封住，绕外围至少要三次拐弯
    const state = board(['xxxx', 'axba', 'xxxx']);
    expect(connectionPath(state, at(state, 0, 1), at(state, 3, 1))).toBeNull();
  });

  it('一次拐弯可连', () => {
    const state = board(['a.', '.a']);
    const path = connectionPath(state, at(state, 0, 0), at(state, 1, 1));
    expect(path).not.toBeNull();
    expect(path).toHaveLength(3);
  });

  it('两次拐弯可连（直连与一次拐弯都被挡住时）', () => {
    // 行 0 向右被 x 挡、列 0 向下再向右被 x 挡，只剩「下 → 右 → 下」的两次拐弯路线
    const state = board(['a.x.', '....', '.x.a']);
    const path = connectionPath(state, at(state, 0, 0), at(state, 3, 2));
    expect(path).not.toBeNull();
    expect(path).toHaveLength(4);
  });

  it('棋盘外围一圈可绕行：贴着两端的同图案牌可连', () => {
    const state = board(['abba', 'bccb', 'bccb', 'abba']);
    // 左上角与右上角都是 a，走上方外围一圈即可连上（一次拐弯出界、一次拐回）
    expect(connectionPath(state, at(state, 0, 0), at(state, 3, 0))).not.toBeNull();
  });

  it('需要三次拐弯的组合判为不可连', () => {
    // 中间被完全堵死，只能绕行三次拐弯
    const state = board(['a.bb', 'bb.b', 'bbb.', '..ba']);
    expect(connectionPath(state, at(state, 0, 0), at(state, 3, 3))).toBeNull();
  });

  it('图案不同或点到自己一律不可连', () => {
    const state = board(['ab']);
    expect(connectionPath(state, at(state, 0, 0), at(state, 1, 0))).toBeNull();
    expect(connectionPath(state, at(state, 0, 0), at(state, 0, 0))).toBeNull();
  });

  it('findPath 对空棋盘上的任意两点都能给出折线', () => {
    const state = board(['a...a']);
    const path = findPath(state.tiles, state.rows, state.cols, { x: 0, y: 0 }, { x: 4, y: 0 });
    expect(path?.[0]).toEqual({ x: 0, y: 0 });
    expect(path?.[path.length - 1]).toEqual({ x: 4, y: 0 });
  });
});

describe('连连看：点选与消除', () => {
  it('首次点选进入 playing 并记录选中', () => {
    const state = selectTile(board(['aa']), 0);
    expect(state.selected).toBe(0);
    expect(state.status).toBe('playing');
    expect(state.moves).toBe(0);
  });

  it('再次点同一张取消选中', () => {
    const first = selectTile(board(['aa']), 0);
    expect(selectTile(first, 0).selected).toBeNull();
  });

  it('可连的一对消除后剩余牌数 −2、尝试 +1，并记录折线', () => {
    const start = board(['aa']);
    const after = selectTile(selectTile(start, 0), 1);
    expect(after.tiles).toEqual([null, null]);
    expect(after.remaining).toBe(0);
    expect(after.moves).toBe(1);
    expect(after.lastPath).not.toBeNull();
    expect(after.status).toBe('won');
    expect(clearPath(after).lastPath).toBeNull();
  });

  it('不可连的一对只改选中并记一次尝试', () => {
    const start = board(['xxxx', 'axba', 'xxxx']);
    const after = selectTile(selectTile(start, at(start, 0, 1)), at(start, 3, 1));
    expect(after.selected).toBe(at(start, 3, 1));
    expect(after.moves).toBe(1);
    expect(after.remaining).toBe(start.remaining);
  });

  it('点空位与胜利后点击都是空操作', () => {
    const start = board(['a.a']);
    expect(selectTile(start, 1)).toEqual(start);
    const won = selectTile(selectTile(start, 0), 2);
    expect(won.status).toBe('won');
    expect(selectTile(won, 0)).toEqual(won);
  });
});

describe('连连看：死局、洗牌与提示', () => {
  it('findAvailableMove 在死局棋面上返回 null', () => {
    // 满盘且同图案两两成对角：内部牌四邻全被占死，边缘牌绕外围都要三次拐弯
    expect(findAvailableMove(board(['abcd', 'badc', 'cdab', 'dcba']))).toBeNull();
  });

  it('死局棋面经 ensurePlayable 洗牌后恢复可玩', () => {
    const stuck = board(['abcd', 'badc', 'cdab', 'dcba']);
    const rescued = ensurePlayable(stuck);
    expect(rescued.shuffles).toBe(1);
    expect(findAvailableMove(rescued)).not.toBeNull();
    expect(rescued.remaining).toBe(stuck.remaining);
  });

  it('洗牌保留剩余牌的图案多重集合，并计入洗牌次数', () => {
    const start = createInitialState(2, 'shuffle-seed');
    const [a, b] = findAvailableMove(start) as [number, number];
    const played = selectTile(selectTile(start, a), b);
    const shuffled = shuffleBoard(played);
    const count = (state: OnetState) => {
      const map = new Map<number, number>();
      state.tiles.forEach((tile) => {
        if (tile === null) return;
        map.set(tile, (map.get(tile) ?? 0) + 1);
      });
      return [...map.entries()].sort((a, b) => a[0] - b[0]);
    };
    expect(count(shuffled)).toEqual(count(played));
    expect(shuffled.remaining).toBe(played.remaining);
    expect(shuffled.shuffles).toBe(1);
    expect(shuffled.selected).toBeNull();
  });

  it('洗牌后棋面必有可消对（死局自救）', () => {
    const start = createInitialState(2, 'rescue');
    const shuffled = shuffleBoard(start);
    expect(findAvailableMove(shuffled)).not.toBeNull();
  });

  it('ensurePlayable 对有解棋面不做改动', () => {
    const start = createInitialState(0, 'playable');
    expect(ensurePlayable(start)).toEqual(start);
  });

  it('提示给出一对真的可消的牌并计数', () => {
    const start = createInitialState(1, 'hint-seed');
    const hinted = hint(start);
    expect(hinted.hints).toBe(1);
    const pair = hinted.hintPair as [number, number];
    expect(connectionPath(hinted, pair[0], pair[1])).not.toBeNull();
    expect(clearHint(hinted).hintPair).toBeNull();
  });
});

describe('连连看：发牌与重开', () => {
  it('每档难度牌面数与图案成对', () => {
    LEVELS.forEach((level, index) => {
      const state = createInitialState(index, 'deal');
      expect(state.tiles).toHaveLength(level.rows * level.cols);
      expect(state.remaining).toBe(level.rows * level.cols);
      const counts = new Map<number, number>();
      state.tiles.forEach((tile) => counts.set(tile as number, (counts.get(tile as number) ?? 0) + 1));
      for (const count of counts.values()) expect(count % 2).toBe(0);
    });
  });

  it('开局保证至少有一对可消', () => {
    for (const seed of ['s1', 's2', 's3', 's4']) {
      expect(findAvailableMove(createInitialState(2, seed))).not.toBeNull();
    }
  });

  it('重开换新牌面，但同一基准种子的第 N 局完全可复现', () => {
    const first = createInitialState(2, 'replay');
    const second = restart(first);
    expect(second.round).toBe(1);
    expect(second.tiles).not.toEqual(first.tiles);
    expect(second).toEqual(createInitialState(2, 'replay', 1));
    expect(dealSeed('replay', 1)).toBe('replay#1');
    expect(dealSeed('replay', 1, 2)).toBe('replay#1!2');
  });

  it('连开 6 局牌面互不重复', () => {
    const layouts = new Set<string>();
    let state = createInitialState(1, 'no-repeat');
    for (let round = 0; round < 6; round += 1) {
      layouts.add(state.tiles.join(','));
      state = restart(state);
    }
    expect(layouts.size).toBe(6);
  });

  it('levelAt 对越界下标回退到默认档位', () => {
    expect(levelAt(99)).toEqual(LEVELS[DEFAULT_LEVEL]);
  });

  it('关卡阶梯从 4×4 一路长到 8×8 封顶', () => {
    expect(boardForStage(1)).toMatchObject({ rows: 4, cols: 4 });
    expect(boardForStage(3)).toMatchObject({ rows: 6, cols: 6 });
    expect(boardForStage(5)).toMatchObject({ rows: 8, cols: 8 });
    // 封顶之后继续升级也不再变大
    expect(boardForStage(50)).toEqual(boardForStage(5));
  });
});

describe('连连看：计分', () => {
  it('消对得分，失败尝试/提示/洗牌扣分', () => {
    const start = board(['aa']);
    const won = selectTile(selectTile(start, 0), 1);
    expect(scoreFor(won)).toBe(100);
    expect(scoreFor({ ...won, moves: 3 })).toBe(80);
    expect(scoreFor({ ...won, hints: 1 })).toBe(50);
    expect(scoreFor({ ...won, shuffles: 2 })).toBe(40);
  });

  it('扣到负分时归零', () => {
    const start = board(['aa']);
    expect(scoreFor({ ...start, hints: 10 })).toBe(0);
  });
});
