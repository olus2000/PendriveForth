from moviepy.video.io.VideoFileClip import VideoFileClip
from math import floor, ceil


blocks = {0   : (0, 0  , 0  , 0  ), 0xdb: (255, 255, 255, 255),
          0xdc: (0, 0  , 255, 255), 0xdd: (255, 0  , 255, 0  ),
          0xde: (0, 255, 0  , 255), 0xdf: (255, 255, 0  , 0  )}


def get_quarters(frame, x, y):
    # Each x encompasses 8 pixels -> 4 px quarter width
    # Each y encompasses 14.4 pixels -> 7.2 quarter height
    # Quarter area: 4 * 7.2 = 28.8
    ans = []
    for yi in (2*y, 2*y+1):
        low = 7.2 * yi
        high = low + 7.2
        for xi in (2*x, 2*x+1):
            ans.append(
                (sum(frame[floor(low)][i][0] for i in range(4 * xi, 4 * xi + 4))
                 * (ceil(low) - low)
                 + sum(frame[yii][xii][0]
                       for yii in range(ceil(low), floor(high))
                       for xii in range(4 * xi, 4 * xi + 4))
                 + (sum(frame[floor(high)][i][0]
                        for i in range(4 * xi, 4 * xi + 4))
                    if high < 360 else 0)
                 * (high - floor(high))
                ) / 28.8
            )
    return ans


def get_best_fit(frame, x, y):
    qs = get_quarters(frame, x, y)
    best = 0
    fit = 4000000000000
    for k, v in blocks.items():
        nfit = sum(abs(a - b) for a, b in zip(qs, v))
        if nfit < fit:
            best = k
            fit = nfit
    return best


def process(clip, out):
    screen = [[0] * 80 for i in range(25)]
    n = 0
    for i, frame in enumerate(clip.iter_frames(logger='bar')):
        print('db ', end='', file=out)
        cursor = -1
        for y in range(25):
            for x in range(10, 70):
                v = get_best_fit(frame, x - 10, y)
                if screen[y][x] != v:
                    while cursor + 255 < x + y * 80:
                        cursor += 255
                        print(255, screen[cursor // 80][cursor % 80], sep=', ', end=', ', file=out)
                    print(80 * y + x - cursor, v, sep=', ', end=', ', file=out)
                    cursor = 80 * y + x
                    screen[y][x] = v
        # if i > 500: return
        print(0, file=out)


if __name__ == '__main__':
    with open('bad_apple.asm', 'w') as out:
        with VideoFileClip('BadApple.mp4') as clip:
            process(clip, out)
#           for y in range(360):
#               for x in range(480):
#                   if clip.get_frame(30)[y][x][0] > 25:
#                       print('X', end='')
#                   else:
#                       print('.', end='')
#               print()
